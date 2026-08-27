use strict;
use warnings;
use Test::More;
use lib 't/lib';

use Test::WWW::MikroTik::MockUA;
use WWW::MikroTik;

# request() is the one place URL, auth, content-type and body all get built -
# every verb is a thin wrapper on top of it, so these tests hit request()
# directly rather than going through get/put/etc.

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

subtest 'default scheme/port, leading slash added to a bare path' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/ip/address' => [] }
  );
  my $mt = _mt(ua => $ua);

  $mt->request('GET', 'ip/address', undef);

  is scalar @{ $ua->requests }, 1, 'one request sent';
  my $req = $ua->requests->[0];
  is $req->method, 'GET', 'method is GET';
  is $req->uri->as_string, 'https://router.example/rest/ip/address',
    'https, no port, leading slash added for a path that lacked one';
};

subtest 'query string: keys sorted, values verbatim (AND filter)' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/ip/address' => [] }
  );
  my $mt = _mt(ua => $ua);

  $mt->request('GET', '/ip/address', undef, network => '10.155.101.0', dynamic => 'true');

  is $ua->requests->[0]->uri->as_string,
    'https://router.example/rest/ip/address?dynamic=true&network=10.155.101.0',
    'query params sorted by key, values passed through unchanged';
};

subtest '.id segment lands in the path unencoded' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/ip/address/*1A' => { '.id' => '*1A' } }
  );
  my $mt = _mt(ua => $ua);

  $mt->request('GET', '/ip/address/*1A', undef);

  my $req = $ua->requests->[0];
  is $req->uri->path, '/rest/ip/address/*1A', 'asterisk survives in the path as-is';
  is $req->uri->as_string, 'https://router.example/rest/ip/address/*1A',
    'full URL keeps the literal *1A';
  unlike $req->uri->as_string, qr/%2[Aa]/,
    'the * is never percent-encoded (that would 404 on a real router)';
};

subtest 'custom scheme and port both reach the URL' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/ip/address' => [] }
  );
  my $mt = _mt(ua => $ua, scheme => 'http', port => 8728);

  $mt->request('GET', '/ip/address', undef);

  is $ua->requests->[0]->uri->as_string, 'http://router.example:8728/rest/ip/address',
    'http scheme and explicit port both applied';
};

subtest 'HTTP Basic auth header carries user and password' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/ip/address' => [] }
  );
  my $mt = _mt(ua => $ua);

  $mt->request('GET', '/ip/address', undef);

  my ( $user, $password ) = $ua->requests->[0]->authorization_basic;
  is $user, 'admin', 'user';
  is $password, 's3cr3t', 'password';
};

subtest 'Content-Type is set only when a body is sent' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => {
      'GET /rest/ip/address' => [],
      'PUT /rest/ip/address' => { '.id' => '*A' }
    }
  );
  my $mt = _mt(ua => $ua);

  $mt->request('GET', '/ip/address', undef);
  ok !$ua->requests->[0]->header('Content-Type'), 'no body, no Content-Type header';

  $mt->request('PUT', '/ip/address', { address => '192.168.111.111', interface => 'dummy' });
  is $ua->requests->[1]->header('Content-Type'), 'application/json',
    'Content-Type appears once a body is sent';
};

subtest 'body bytes are canonical (sorted-key) JSON' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'PUT /rest/ip/address' => { '.id' => '*A' } }
  );
  my $mt = _mt(ua => $ua);

  $mt->request('PUT', '/ip/address', { interface => 'dummy', address => '192.168.111.111' });

  is $ua->requests->[0]->content, '{"address":"192.168.111.111","interface":"dummy"}',
    'keys serialized alphabetically regardless of insertion order into the hash';
};

done_testing;
