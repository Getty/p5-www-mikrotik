#!/usr/bin/env perl
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

subtest 'Basic auth header: exact bytes, and the defaults admin / empty password' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/ip/address' => [] }
  );

  _mt(ua => $ua)->request('GET', '/ip/address', undef);
  is $ua->requests->[0]->header('Authorization'), 'Basic YWRtaW46czNjcjN0',
    'base64("admin:s3cr3t")';

  my $default = WWW::MikroTik->new( host => 'router.example', ua => $ua );
  $default->request('GET', '/ip/address', undef);
  is $ua->requests->[1]->header('Authorization'), 'Basic YWRtaW46', 'base64("admin:")';
  my ( $user, $password ) = $ua->requests->[1]->authorization_basic;
  is $user, 'admin', 'default user is admin';
  is $password, '', 'default password is the empty string';
};

subtest 'every HTTP method reaches the wire as given, auth on all of them' => sub {
  my $routes = { map { ( $_.' /rest/ip/address' => {} ) } qw( GET PUT PATCH DELETE POST ) };
  my $ua = Test::WWW::MikroTik::MockUA->new( routes => $routes );
  my $mt = _mt(ua => $ua);

  $mt->request($_, '/ip/address', undef) for qw( GET PUT PATCH DELETE POST );

  is_deeply [ map { $_->method } @{ $ua->requests } ], [ qw( GET PUT PATCH DELETE POST ) ],
    'methods in order, unchanged';
  is $_->header('Authorization'), 'Basic YWRtaW46czNjcjN0', $_->method.' carries auth'
    for @{ $ua->requests };
  is $_->content, '', $_->method.' with an undef body sends nothing'
    for @{ $ua->requests };
  ok !defined $_->header('Content-Type'), $_->method.' with an undef body has no Content-Type'
    for @{ $ua->requests };
};

subtest 'an empty hashref is still a body: {} and Content-Type' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/system/resource/print' => [] }
  );
  _mt(ua => $ua)->request('POST', '/system/resource/print', {});

  my $req = $ua->requests->[0];
  is $req->content, '{}', 'empty object';
  is $req->header('Content-Type'), 'application/json', 'Content-Type present';
};

subtest 'query string and body together' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/ip/address' => {} }
  );
  _mt(ua => $ua)->request('POST', '/ip/address', { a => '1' }, b => '2');

  my $req = $ua->requests->[0];
  is $req->uri->as_string, 'https://router.example/rest/ip/address?b=2', 'query in the URL';
  is $req->content, '{"a":"1"}', 'body in the body';
};

subtest 'request() returns the decoded response' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => {
      'GET /rest/interface/ether1' => { '.id' => '*1', name => 'ether1', type => 'ether' },
      'GET /rest/interface'        => [ { '.id' => '*1', name => 'ether1' } ]
    }
  );
  my $mt = _mt(ua => $ua);

  is_deeply $mt->request('GET', '/interface/ether1', undef),
    { '.id' => '*1', name => 'ether1', type => 'ether' }, 'hashref for a single record';
  is_deeply $mt->request('GET', '/interface', undef), [ { '.id' => '*1', name => 'ether1' } ],
    'arrayref for a menu';
};

subtest 'a base_url with a path prefix keeps it' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /gw/rest/ip/address' => [] }
  );
  my $mt = _mt(ua => $ua, base_url => 'https://router.example/gw/rest');
  $mt->request('GET', 'ip/address', undef);

  is $ua->requests->[0]->uri->as_string, 'https://router.example/gw/rest/ip/address',
    'prefix kept, slash added';
};

done_testing;
