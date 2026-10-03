#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Log::Any::Test;
use Log::Any qw( $log );
use lib 't/lib';

use JSON::MaybeXS;
use Test::WWW::MikroTik::MockUA;
use WWW::MikroTik;

# The debug log shows request bodies and URLs. Values of password-like keys
# are masked in the logged copy only - what goes to the router is unchanged.

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

sub _debug { join "\n", map { $_->{message} } grep { $_->{level} eq 'debug' } @{ $log->msgs } }

my $json = JSON::MaybeXS->new( utf8 => 1 );

subtest 'request body: password masked in the log, real value on the wire' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'PUT /rest/ppp/secret' => { '.id' => '*1' } }
  );
  my $mt = _mt(ua => $ua);
  $log->clear;

  $mt->add('/ppp/secret', name => 'alice', password => 'hunter2', service => 'pppoe');

  is $ua->requests->[0]->content,
    '{"name":"alice","password":"hunter2","service":"pppoe"}',
    'wire body bytes carry the real password';

  my $debug = _debug();
  unlike $debug, qr/hunter2/, 'the password value is not in the debug log';
  like $debug, qr/^Body: \{"name":"alice","password":"\*\*\*","service":"pppoe"\}$/m,
    'the logged body is the same JSON with the value replaced by ***';
  unlike $debug, qr/s3cr3t/, 'the Basic auth password is not logged either';
};

subtest 'every password-like key is masked, case-insensitively' => sub {
  my @keys = qw(
    password old-password new-password confirm-new-password
    authentication-password encryption-password
    wpa2-pre-shared-key preshared-key passphrase secret ipsec-secret
    private-key Password
  );
  my %data = ( comment => 'visible', map { ( $_ => 'leak-'.$_ ) } @keys );
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/some/command' => [] }
  );
  my $mt = _mt(ua => $ua);
  $log->clear;

  $mt->cmd('/some/command', %data);

  is_deeply $json->decode($ua->requests->[0]->content), { %data },
    'wire body carries every real value';

  my $debug = _debug();
  unlike $debug, qr/leak-/, 'none of the values is in the debug log';
  like $debug, qr/"\Q$_\E":"\*\*\*"/, $_.' is masked' for @keys;
  like $debug, qr/"comment":"visible"/, 'an ordinary key is logged verbatim';
};

subtest 'structural rule: token, psk, key and *-key masked; public-key and look-alikes visible' => sub {
  my @masked = qw(
    auth-key authentication-key tcp-md5-key static-key psk token KEY key
  );
  my @visible = qw(
    public-key passthrough keepalive key-size name comment
  );
  my %data = (
    ( map { ( $_ => 'leak-'.$_ ) } @masked ),
    ( map { ( $_ => 'shown-'.$_ ) } @visible )
  );
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/some/command' => [], 'GET /rest/some/menu' => [] }
  );
  my $mt = _mt(ua => $ua);
  $log->clear;

  $mt->cmd('/some/command', %data);
  $mt->list('/some/menu', %data);

  is_deeply $json->decode($ua->requests->[0]->content), { %data },
    'wire body carries every real value';
  is_deeply { $ua->requests->[1]->uri->query_form }, { %data },
    'wire query string carries every real value';

  my $debug = _debug();
  unlike $debug, qr/leak-/, 'none of the masked values is in the debug log';
  for my $key (@masked) {
    like $debug, qr/"\Q$key\E":"\*\*\*"/, $key.' is masked in the body';
    like $debug, qr/[?&]\Q$key\E=\*\*\*(?:&|$)/m, $key.' is masked in the query string';
  }
  for my $key (@visible) {
    like $debug, qr/"\Q$key\E":"shown-\Q$key\E"/, $key.' is visible in the body';
    like $debug, qr/[?&]\Q$key\E=shown-\Q$key\E(?:&|$)/m, $key.' is visible in the query string';
  }
};

subtest 'the data passed in is not modified' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'PATCH /rest/user/*1' => { '.id' => '*1' } }
  );
  my $mt = _mt(ua => $ua);
  my $data = { password => 'hunter2' };

  $mt->patch('/user/*1', $data);

  is_deeply $data, { password => 'hunter2' }, 'the hashref passed in still holds the real value';
};

subtest 'query string: password masked in the logged URL, real value on the wire' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/ppp/secret' => [] }
  );
  my $mt = _mt(ua => $ua);
  $log->clear;

  $mt->list('/ppp/secret', password => 'hunter2', name => 'alice');

  is $ua->requests->[0]->uri->as_string,
    'https://router.example/rest/ppp/secret?name=alice&password=hunter2',
    'wire URL carries the real password';

  my $debug = _debug();
  unlike $debug, qr/hunter2/, 'the password value is not in the debug log';
  like $debug, qr{^GET https://router\.example/rest/ppp/secret\?name=alice&password=\*\*\*$}m,
    'the logged URL is the same URL with the value replaced by ***';
};

subtest 'not masked: a value inside a .query word' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/ppp/secret/print' => [] }
  );
  my $mt = _mt(ua => $ua);
  $log->clear;

  $mt->print('/ppp/secret', query => [ 'password=hunter2' ]);

  like _debug(), qr/password=hunter2/,
    'logged as sent - only top-level keys are looked at';
};

my @masked_names = qw(
  password Password old-password new-password confirm-new-password
  passphrase wpa2-pre-shared-key secret ipsec-secret token psk key
  private-key auth-key tcp-md5-key pre-shared-key
);
my @visible_names = qw( public-key PUBLIC-KEY passthrough keepalive key-size keys );

subtest 'every masked name, in the body and in the query, wire untouched' => sub {
  my %data = map { ( $_ => 'leak-'.$_ ) } @masked_names;
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'PATCH /rest/x/*1' => {}, 'GET /rest/x' => [] }
  );
  my $mt = _mt(ua => $ua);
  $log->clear;

  $mt->set('/x', '*1', %data);
  my $body_log = _debug();
  $log->clear;
  $mt->list('/x', %data);
  my $query_log = _debug();

  is_deeply $json->decode($ua->requests->[0]->content), { %data }, 'wire body is unmasked';
  is_deeply { $ua->requests->[1]->uri->query_form }, { %data }, 'wire query is unmasked';
  unlike $body_log, qr/leak-/, 'no value in the body log';
  unlike $query_log, qr/leak-/, 'no value in the query log';
  like $body_log, qr/"\Q$_\E":"\*\*\*"/, $_.' masked in the body' for @masked_names;
  like $query_log, qr/[?&]\Q$_\E=\*\*\*(?:&|$)/m, $_.' masked in the query' for @masked_names;
};

subtest 'names that must stay visible, in the body and in the query' => sub {
  my %data = map { ( $_ => 'shown-'.$_ ) } @visible_names;
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'PUT /rest/x' => {}, 'GET /rest/x' => [] }
  );
  my $mt = _mt(ua => $ua);
  $log->clear;

  $mt->add('/x', %data);
  my $body_log = _debug();
  $log->clear;
  $mt->list('/x', %data);
  my $query_log = _debug();

  unlike $body_log.$query_log, qr/\*\*\*/, 'nothing masked';
  like $body_log, qr/"\Q$_\E":"shown-\Q$_\E"/, $_.' visible in the body' for @visible_names;
  like $query_log, qr/[?&]\Q$_\E=shown-\Q$_\E(?:&|$)/m, $_.' visible in the query'
    for @visible_names;
};

subtest 'the vendor /password command: all three fields masked, wire intact' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/password' => [] }
  );
  my $mt = _mt(ua => $ua);
  $log->clear;

  $mt->cmd('/password',
    'old-password' => 'old', 'new-password' => 'N3w', 'confirm-new-password' => 'N3w');

  is $ua->requests->[0]->content,
    '{"confirm-new-password":"N3w","new-password":"N3w","old-password":"old"}',
    'wire body';
  like _debug(),
    qr/^Body: \{"confirm-new-password":"\*\*\*","new-password":"\*\*\*","old-password":"\*\*\*"\}$/m,
    'logged body';
};

subtest 'the Basic auth credentials appear in no log message of any level' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => {
      'GET /rest/ok'  => [],
      'GET /rest/bad' => { error => 401, message => 'Unauthorized' },
      'PUT /rest/ok'  => {}
    }
  );
  my $mt = WWW::MikroTik->new(
    host => 'router.example', user => 'svc-uniq', password => 'pw-uniq-9', ua => $ua
  );
  $log->clear;

  $mt->list('/ok');
  $mt->add('/ok', comment => 'x');
  eval { $mt->list('/bad') };

  my $all = join "\n", map { $_->{message} } @{ $log->msgs };
  ok length $all, 'something was logged';
  unlike $all, qr/pw-uniq-9/, 'password not logged';
  unlike $all, qr/svc-uniq/, 'user name not logged';
  unlike $all, qr/Basic|Authorization/i, 'no auth header logged';
  my $b64 = $ua->requests->[0]->header('Authorization') =~ s/\ABasic //r;
  unlike $all, qr/\Q$b64\E/, 'the base64 credentials are not logged';
};

subtest 'an arrayref query value is masked as a whole' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/x' => [] }
  );
  $log->clear;
  _mt(ua => $ua)->list('/x', key => [ 'k1', 'k2' ], name => [ 'a', 'b' ]);
  my $query = $ua->requests->[0]->uri->as_string;

  like $query, qr/key=k1%2Ck2/, 'wire carries the joined values';
  my $debug = _debug();
  like $debug, qr/[?&]key=\*\*\*(?:&|$)/m, 'one ***, not one per element';
  unlike $debug, qr/k1|k2/, 'no element is logged';
  like $debug, qr/name=a%2Cb/, 'an ordinary arrayref is logged joined';
};

subtest 'nested structures are not masked (documented limit)' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/some/command' => [] }
  );
  $log->clear;
  _mt(ua => $ua)->cmd('/some/command', outer => { password => 'nested-leak' }, list => [ 'secret' ]);
  my $debug = _debug();

  like $debug, qr/"outer":\{"password":"nested-leak"\}/, 'nested hash logged as sent';
  like $debug, qr/"list":\["secret"\]/, 'array of words logged as sent';
};

subtest 'info line: method, path and status, no query or body' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/ppp/secret' => [] }
  );
  $log->clear;
  _mt(ua => $ua)->list('/ppp/secret', password => 'hunter2');

  my @info = map { $_->{message} } grep { $_->{level} eq 'info' } @{ $log->msgs };
  is $info[-1], 'GET /ppp/secret -> 200', 'the info line';
};

subtest 'GET without a query logs the bare URL and no Body line' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/ip/address' => [] }
  );
  $log->clear;
  _mt(ua => $ua)->list('/ip/address');

  is _debug(), 'GET https://router.example/rest/ip/address', 'one debug line';
};

done_testing;
