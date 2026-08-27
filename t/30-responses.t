use strict;
use warnings;
use Test::More;
use Test::Fatal qw( exception );
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

done_testing;
