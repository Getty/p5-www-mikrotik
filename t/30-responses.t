#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Fatal qw( exception );
use Log::Any::Test;
use Log::Any qw( $log );
use lib 't/lib';

use HTTP::Response;
use Test::WWW::MikroTik::MockUA;
use WWW::MikroTik;

# Response decoding (list / single object / empty body) and the error croak
# path. Fixtures are verbatim from the vendor reference.

sub _mt {
  my ( %args ) = @_;
  my $ua = delete $args{ua};
  return WWW::MikroTik->new(
    host     => 'router.example',
    user     => 'admin',
    password => 's3cr3t',
    ua       => $ua,
    %args
  );
}

subtest 'GET list decodes to an arrayref of records, values stay strings' => sub {
  my $addresses = [
    { '.id' => '*1', 'actual-interface' => 'ether2', address => '10.0.0.111/24',
      disabled => 'false', dynamic => 'false', interface => 'ether2', invalid => 'false',
      network => '10.0.0.0' },
    { '.id' => '*2', 'actual-interface' => 'ether3', address => '10.0.0.109/24',
      disabled => 'true', dynamic => 'false', interface => 'ether3', invalid => 'false',
      network => '10.0.0.0' }
  ];
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/ip/address' => $addresses }
  );
  my $mt = _mt(ua => $ua);

  my $result = $mt->get('/ip/address');

  is_deeply $result, $addresses, 'decoded verbatim';
  is $result->[0]{disabled}, 'false', 'disabled is the string "false", not a JSON boolean';
  is $result->[1]{disabled}, 'true', 'disabled is the string "true" on the other record';
};

subtest 'GET by .id decodes to a single object, not a one-element list' => sub {
  my $address = {
    '.id' => '*1', 'actual-interface' => 'ether2', address => '10.0.0.111/24',
    disabled => 'false', dynamic => 'false', interface => 'ether2', invalid => 'false',
    network => '10.0.0.0'
  };
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/ip/address/*1' => $address }
  );
  my $mt = _mt(ua => $ua);

  is_deeply $mt->get('/ip/address/*1'), $address;
};

subtest 'empty body decodes to nothing (DELETE success)' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'DELETE /rest/ip/address/*9' => HTTP::Response->new(200) }
  );
  my $mt = _mt(ua => $ua);

  is $mt->delete('/ip/address/*9'), undef, 'no content -> undef, not an exception';
};

subtest 'a command with neither !re nor !done data decodes to an empty list' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/some/command' => [] }
  );
  my $mt = _mt(ua => $ua);

  is_deeply $mt->cmd('/some/command'), [], 'empty JSON array, distinct from undef';
};

subtest 'error: 404 Not Found, no detail field' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'DELETE /rest/ip/address/*9' => { error => 404, message => 'Not Found' } }
  );
  my $mt = _mt(ua => $ua);

  my $err = exception { $mt->remove('/ip/address', '*9') };
  ok $err, 'remove croaked';
  like $err, qr/\AWWW::MikroTik: 404 Not Found/, 'status and message, no trailing colon when detail is absent';
};

subtest 'error: 406 Not Acceptable, with detail' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => {
      'POST /rest/ip/address' => {
        error   => 406,
        message => 'Not Acceptable',
        detail  => 'no such command or directory (remove)'
      }
    }
  );
  my $mt = _mt(ua => $ua);

  my $err = exception { $mt->post('/ip/address', {}) };
  ok $err, 'post croaked';
  like $err, qr/\AWWW::MikroTik: 406 Not Acceptable: no such command or directory \(remove\)/,
    'status, message and detail all present, joined as documented';
};

subtest 'error: 400 Bad Request / "Session closed" (60s timeout), key order in the body does not matter' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => {
      'POST /rest/ping' => { detail => 'Session closed', error => 400, message => 'Bad Request' }
    }
  );
  my $mt = _mt(ua => $ua);

  my $err = exception { $mt->cmd('/ping', address => '10.155.101.1') };
  ok $err, 'cmd croaked';
  like $err, qr/\AWWW::MikroTik: 400 Bad Request: Session closed/,
    'a request-timeout error surfaces as a normal error croak';
};

subtest 'error: 2xx with a non-JSON body croaks with the module prefix, not the raw decoder error' => sub {
  my $html = HTTP::Response->new(200, 'OK', [ 'Content-Type' => 'text/html' ],
    '<html><body>captive portal</body></html>');
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/ip/address' => $html }
  );
  my $mt = _mt(ua => $ua);
  $log->clear;

  my $file = __FILE__;
  my $err  = exception { $mt->get('/ip/address') }; my $line = __LINE__;
  ok $err, 'get croaked';
  like $err, qr/\AWWW::MikroTik: 200 OK: response body is not JSON: \S/,
    'prefix, HTTP status line, what is wrong, and the decoder reason';
  like $err, qr/ at \Q$file\E line $line\.\n\z/, 'reported from the caller';
  is scalar( () = $err =~ / line \d+/g ), 1,
    'exactly one source location - the decoder\'s own " at ... line N." is trimmed';

  my ( $logged ) = grep { $_->{level} eq 'error' } @{ $log->msgs };
  ok $logged, 'logged at error';
  like $logged->{message}, qr/\AWWW::MikroTik: 200 OK: response body is not JSON: \S/,
    'the error log line is the croak message';
  unlike $logged->{message}, qr/ line \d+/, 'without a source location';
};

#### Empty bodies

subtest 'empty body: undef in scalar context, no elements in list context' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'DELETE /rest/ip/address/*9' => HTTP::Response->new(200) }
  );
  my $mt = _mt(ua => $ua);

  my $scalar = $mt->delete('/ip/address/*9');
  is $scalar, undef, 'scalar context';
  my @list = $mt->delete('/ip/address/*9');
  is scalar @list, 0, 'list context returns the empty list, not (undef)';
  @list = $mt->remove('/ip/address', '*9');
  is scalar @list, 0, 'remove, list context';
  @list = $mt->request('DELETE', '/ip/address/*9');
  is scalar @list, 0, 'request, list context';
};

subtest '204 No Content decodes to nothing' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'DELETE /rest/ip/address/*9' => HTTP::Response->new(204, 'No Content') }
  );
  my $mt = _mt(ua => $ua);

  is scalar( $mt->remove('/ip/address', '*9') ), undef, 'scalar context';
  my @list = $mt->remove('/ip/address', '*9');
  is scalar @list, 0, 'list context';
};

subtest 'an empty JSON array is a value, not an empty result' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/some/command' => [] }
  );
  my @list = _mt(ua => $ua)->cmd('/some/command');

  is scalar @list, 1, 'one element in list context';
  is_deeply $list[0], [], 'the empty arrayref';
};

subtest 'a command with !done data decodes to an object' => sub {
  my $res = { ret => '*5' };
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/execute' => $res }
  );

  is_deeply _mt(ua => $ua)->cmd('/execute', script => '/log/info test'), $res;
};

#### Errors

my @errors = (
  [ 400, 'Bad Request',           undef,                                    'POST /rest/ping' ],
  [ 400, 'Bad Request',           'Session closed',                         'POST /rest/ping' ],
  [ 400, 'Bad Request',           'failure: already have such address',     'POST /rest/ping' ],
  [ 401, 'Unauthorized',          undef,                                    'POST /rest/ping' ],
  [ 404, 'Not Found',             undef,                                    'POST /rest/ping' ],
  [ 406, 'Not Acceptable',        'no such command or directory (remove)',  'POST /rest/ping' ],
  [ 500, 'Internal Server Error', undef,                                    'POST /rest/ping' ],
  [ 500, 'Internal Server Error', 'something broke',                        'POST /rest/ping' ],
);

for my $case (@errors) {
  my ( $code, $message, $detail ) = @$case;
  my $name = $code.' '.$message.( defined $detail ? ' with detail' : ' without detail' );

  subtest 'error: '.$name => sub {
    my $body = { error => $code, message => $message, defined $detail ? ( detail => $detail ) : () };
    my $ua = Test::WWW::MikroTik::MockUA->new(
      routes => { 'POST /rest/ping' => $body }
    );
    my $mt = _mt(ua => $ua);
    $log->clear;

    my $err = exception { $mt->cmd('/ping', address => '10.155.101.1') };
    my $want = 'WWW::MikroTik: '.$code.' '.$message.( defined $detail ? ': '.$detail : '' );
    like $err, qr/\A\Q$want\E at /, 'message is exactly status, message and optional detail';
    unlike $err, qr/\Q$want\E:/, 'nothing appended after the detail' unless defined $detail;

    my ( $logged ) = grep { $_->{level} eq 'error' } @{ $log->msgs };
    is $logged->{message}, $want, 'logged at error without the source location';
  };
}

subtest 'error body keys in any order and with a different JSON layout' => sub {
  my $res = HTTP::Response->new( 400, 'Bad Request', [ 'Content-Type' => 'application/json' ],
    '{"detail":"failure: already have such address","error":400,"message":"Bad Request"}' );
  my $ua = Test::WWW::MikroTik::MockUA->new( routes => { 'PUT /rest/ip/address' => $res } );

  like exception { _mt(ua => $ua)->add('/ip/address', address => '10.0.0.5/24') },
    qr/\AWWW::MikroTik: 400 Bad Request: failure: already have such address at /;
};

subtest 'the status comes from the HTTP line, not from the body' => sub {
  my $res = HTTP::Response->new( 404, 'Not Found', [ 'Content-Type' => 'application/json' ],
    '{"error":500,"message":"Not Found"}' );
  my $ua = Test::WWW::MikroTik::MockUA->new( routes => { 'GET /rest/x' => $res } );

  like exception { _mt(ua => $ua)->get('/x') }, qr/\AWWW::MikroTik: 404 Not Found at /,
    'the HTTP status is reported';
};

subtest 'error status with a non-JSON body: the status line' => sub {
  my $res = HTTP::Response->new( 502, 'Bad Gateway', [ 'Content-Type' => 'text/html' ],
    '<html><body><h1>502 Bad Gateway</h1></body></html>' );
  my $ua = Test::WWW::MikroTik::MockUA->new( routes => { 'GET /rest/x' => $res } );
  $log->clear;

  my $err = exception { _mt(ua => $ua)->get('/x') };
  like $err, qr/\AWWW::MikroTik: 502 Bad Gateway at /, 'status line';
  unlike $err, qr/<html>/, 'the body is not in the message';
  my ( $logged ) = grep { $_->{level} eq 'error' } @{ $log->msgs };
  is $logged->{message}, 'WWW::MikroTik: 502 Bad Gateway', 'logged';
};

subtest 'error status with an empty body: the status line' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/x' => HTTP::Response->new( 503, 'Service Unavailable' ) }
  );

  like exception { _mt(ua => $ua)->get('/x') },
    qr/\AWWW::MikroTik: 503 Service Unavailable at /;
};

subtest 'error JSON without a message: the status line' => sub {
  my $res = HTTP::Response->new( 400, 'Bad Request', [ 'Content-Type' => 'application/json' ],
    '{"error":400,"detail":"Session closed"}' );
  my $ua = Test::WWW::MikroTik::MockUA->new( routes => { 'GET /rest/x' => $res } );

  like exception { _mt(ua => $ua)->get('/x') }, qr/\AWWW::MikroTik: 400 Bad Request at /,
    'detail alone is not used';
};

subtest 'error JSON that is an array: the status line' => sub {
  my $res = HTTP::Response->new( 500, 'Internal Server Error', [ 'Content-Type' => 'application/json' ],
    '[{"error":500,"message":"Internal Server Error"}]' );
  my $ua = Test::WWW::MikroTik::MockUA->new( routes => { 'GET /rest/x' => $res } );

  like exception { _mt(ua => $ua)->get('/x') },
    qr/\AWWW::MikroTik: 500 Internal Server Error at /;
};

subtest 'status 399 is success, 400 is an error' => sub {
  my $ok  = HTTP::Response->new( 299, 'Odd', [], '{"a":"1"}' );
  my $bad = HTTP::Response->new( 400, 'Bad Request', [], '' );
  my $ua  = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/ok' => $ok, 'GET /rest/bad' => $bad }
  );
  my $mt = _mt(ua => $ua);

  is_deeply $mt->get('/ok'), { a => '1' }, 'below 400 decodes';
  like exception { $mt->get('/bad') }, qr/\AWWW::MikroTik: 400 Bad Request at /, '400 croaks';
};

#### Transport failures (LWP's synthetic responses)

subtest 'connection refused: LWP synthetic 500' => sub {
  my $res = HTTP::Response->new( 500, "Can't connect to router.example:443 (Connection refused)",
    [ 'Client-Warning' => 'Internal response', 'Content-Type' => 'text/plain' ],
    "Can't connect to router.example:443 (Connection refused)\n" );
  my $ua = Test::WWW::MikroTik::MockUA->new( routes => { 'GET /rest/ip/address' => $res } );
  $log->clear;

  my $err = exception { _mt(ua => $ua)->list('/ip/address') };
  like $err,
    qr/\AWWW::MikroTik: 500 Can't connect to router\.example:443 \(Connection refused\) at /,
    'status line, not the plain-text body';
  my ( $logged ) = grep { $_->{level} eq 'error' } @{ $log->msgs };
  is $logged->{message},
    "WWW::MikroTik: 500 Can't connect to router.example:443 (Connection refused)", 'logged';
};

subtest 'timeout: LWP synthetic 500' => sub {
  my $res = HTTP::Response->new( 500, 'read timeout',
    [ 'Client-Warning' => 'Internal response', 'Content-Type' => 'text/plain' ],
    "read timeout\n" );
  my $ua = Test::WWW::MikroTik::MockUA->new( routes => { 'POST /rest/ping' => $res } );

  like exception { _mt(ua => $ua)->cmd('/ping', address => '10.155.101.1', count => '4') },
    qr/\AWWW::MikroTik: 500 read timeout at /;
};

subtest 'a ua that dies: the exception propagates unchanged and is not logged' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/ip/address' => sub { die "ua blew up\n" } }
  );
  $log->clear;

  my $err = exception { _mt(ua => $ua)->list('/ip/address') };
  is $err, "ua blew up\n", 'no WWW::MikroTik prefix, no wrapping';
  is scalar( grep { $_->{level} eq 'error' } @{ $log->msgs } ), 0, 'nothing at error level';
};

#### Where the croak points

subtest 'the croak is reported at the caller, through every wrapper' => sub {
  my $error = { error => 404, message => 'Not Found' };
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => {
      'GET /rest/x'               => $error,
      'PUT /rest/x'               => $error,
      'PATCH /rest/x/*1'          => $error,
      'DELETE /rest/x/*1'         => $error,
      'POST /rest/x'              => $error,
      'POST /rest/x/print'        => $error
    }
  );
  my $mt   = _mt(ua => $ua);
  my $file = __FILE__;
  my ( $err, $line );

  $err = exception { $mt->request('GET', '/x') }; $line = __LINE__;
  like $err, qr/ at \Q$file\E line $line\.\n\z/, 'request';
  $err = exception { $mt->get('/x') }; $line = __LINE__;
  like $err, qr/ at \Q$file\E line $line\.\n\z/, 'get';
  $err = exception { $mt->list('/x') }; $line = __LINE__;
  like $err, qr/ at \Q$file\E line $line\.\n\z/, 'list (two wrappers)';
  $err = exception { $mt->put('/x', {}) }; $line = __LINE__;
  like $err, qr/ at \Q$file\E line $line\.\n\z/, 'put';
  $err = exception { $mt->add('/x') }; $line = __LINE__;
  like $err, qr/ at \Q$file\E line $line\.\n\z/, 'add (two wrappers)';
  $err = exception { $mt->set('/x', '*1') }; $line = __LINE__;
  like $err, qr/ at \Q$file\E line $line\.\n\z/, 'set (two wrappers)';
  $err = exception { $mt->remove('/x', '*1') }; $line = __LINE__;
  like $err, qr/ at \Q$file\E line $line\.\n\z/, 'remove (two wrappers)';
  $err = exception { $mt->post('/x', {}) }; $line = __LINE__;
  like $err, qr/ at \Q$file\E line $line\.\n\z/, 'post';
  $err = exception { $mt->cmd('/x') }; $line = __LINE__;
  like $err, qr/ at \Q$file\E line $line\.\n\z/, 'cmd (two wrappers)';
  $err = exception { $mt->print('/x') }; $line = __LINE__;
  like $err, qr/ at \Q$file\E line $line\.\n\z/, 'print (three wrappers)';
};

#### Decoding

subtest 'a UTF-8 response body decodes to characters' => sub {
  my $res = HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'application/json' ],
    "{\"\.id\":\"*1\",\"comment\":\"B\xc3\xbcro\"}" );
  my $ua = Test::WWW::MikroTik::MockUA->new( routes => { 'GET /rest/interface/*1' => $res } );

  my $rec = _mt(ua => $ua)->get('/interface/*1');
  is $rec->{comment}, "B\x{fc}ro", 'ü is one character';
  is length $rec->{comment}, 4, 'four characters';
};

subtest 'every value of a decoded record is a plain string' => sub {
  my $res = { '.id' => '*1', disabled => 'false', 'cpu-count' => '16', uptime => '2d20h12m20s' };
  my $ua = Test::WWW::MikroTik::MockUA->new( routes => { 'GET /rest/system/resource' => $res } );

  my $rec = _mt(ua => $ua)->get('/system/resource');
  is ref \$rec->{$_}, 'SCALAR', $_.' is not a reference or boolean object' for sort keys %$rec;
  is $rec->{disabled}, 'false', 'disabled stays "false"';
  is $rec->{'cpu-count'}, '16', 'cpu-count stays "16"';
};

done_testing;
