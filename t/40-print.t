#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';

use Test::WWW::MikroTik::MockUA;
use WWW::MikroTik;

# print() is cmd("$path/print", ...) with '.proplist' and '.query' spelled
# for the caller. Both are POST body values (not query-string params), so
# they must reach the wire exactly as given: '.proplist' either as the
# comma-string or as a list, '.query' as its stack, order preserved.

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

subtest '.proplist as a comma-separated string, passed through unchanged' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/interface/print' => [] }
  );
  my $mt = _mt(ua => $ua);

  $mt->print('/interface', proplist => 'name,type');

  is $ua->requests->[0]->content, '{".proplist":"name,type"}',
    'string form of .proplist is not split or otherwise touched';
};

subtest '.proplist as a list, kept as a JSON array (not joined)' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/interface/print' => [] }
  );
  my $mt = _mt(ua => $ua);

  $mt->print('/interface', proplist => [ 'name', 'type' ]);

  is $ua->requests->[0]->content, '{".proplist":["name","type"]}',
    'array form stays a JSON array; both forms are valid per the vendor doc';
};

subtest '.query stack is passed through in order, untouched' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/interface/print' => [] }
  );
  my $mt = _mt(ua => $ua);

  $mt->print('/interface', query => [ 'type=ether', 'type=vlan', '#|' ]);

  is $ua->requests->[0]->content, '{".query":["type=ether","type=vlan","#|"]}',
    'the query stack keeps its element order - it is a stack, not an ANDed set';
};

subtest '.proplist and .query together, verbatim vendor example' => sub {
  my $result = [
    { '.id' => '*8', address => '10.155.101.214/24', interface => 'sfp12' },
    { '.id' => '*A', address => '192.168.111.111/32', interface => 'dummy' }
  ];
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/ip/address/print' => $result }
  );
  my $mt = _mt(ua => $ua);

  my $decoded = $mt->print(
    '/ip/address',
    proplist => [ '.id', 'address', 'interface' ],
    query    => [ 'network=192.168.111.111', 'dynamic=true', '#|' ]
  );

  my $req = $ua->requests->[0];
  is $req->uri->path, '/rest/ip/address/print';
  is $req->content,
    '{".proplist":[".id","address","interface"],".query":["network=192.168.111.111","dynamic=true","#|"]}',
    '.proplist and .query both present, .query order preserved (not sorted like object keys)';
  is_deeply $decoded, $result, 'decoded records match the fixture';
};

subtest 'plain args alongside .proplist/.query still reach the body' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/interface/print' => [] }
  );
  my $mt = _mt(ua => $ua);

  $mt->print('/interface', proplist => 'name', 'running' => 'true');

  is $ua->requests->[0]->content, '{".proplist":"name","running":"true"}',
    'extra console properties pass through next to the dotted protocol keys';
};

subtest 'no arguments: POST, {} body, Content-Type, auth, /print appended' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/interface/print' => [] }
  );
  _mt(ua => $ua)->print('/interface');

  my $req = $ua->requests->[0];
  is $req->method, 'POST', 'POST';
  is $req->uri->as_string, 'https://router.example/rest/interface/print', 'URL';
  is $req->content, '{}', 'empty object body';
  is $req->header('Content-Type'), 'application/json', 'Content-Type';
  is $req->header('Authorization'), 'Basic YWRtaW46czNjcjN0', 'Basic auth';
};

subtest 'proplist or query given as undef is omitted' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/interface/print' => [] }
  );
  my $mt = _mt(ua => $ua);

  $mt->print('/interface', proplist => undef, query => undef);
  $mt->print('/interface', proplist => undef, query => [ 'type=ether' ]);
  $mt->print('/interface', proplist => 'name', query => undef);

  is $ua->requests->[0]->content, '{}', 'both undef';
  is $ua->requests->[1]->content, '{".query":["type=ether"]}', 'proplist undef';
  is $ua->requests->[2]->content, '{".proplist":"name"}', 'query undef';
};

subtest 'the protocol keys never leak under their short names' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/interface/print' => [] }
  );
  _mt(ua => $ua)->print('/interface', proplist => 'name', query => [ 'type=ether' ]);

  unlike $ua->requests->[0]->content, qr/"(?:proplist|query)"/, 'only .proplist and .query';
};

subtest 'proplist and query are body values, never part of the URL' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/interface/print' => [] }
  );
  _mt(ua => $ua)->print('/interface', proplist => [ 'name' ], query => [ 'type=ether' ]);

  is $ua->requests->[0]->uri->query, undef, 'no query string';
};

subtest 'a flag argument (empty string) passes through' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/ip/address/print' => [] }
  );
  _mt(ua => $ua)->print('/ip/address', 'without-paging' => '', proplist => 'address');

  is $ua->requests->[0]->content, '{".proplist":"address","without-paging":""}',
    'dotted keys and plain args in one canonical object';
};

subtest 'extra args next to proplist and query, all sorted' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/interface/print' => [] }
  );
  _mt(ua => $ua)->print('/interface',
    query => [ 'type=ether' ], 'without-paging' => '', proplist => [ 'name' ], 'detail' => '');

  is $ua->requests->[0]->content,
    '{".proplist":["name"],".query":["type=ether"],"detail":"","without-paging":""}',
    'keys sorted, list values keep their order';
};

subtest '/print is appended to a nested menu path' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/ip/firewall/nat/print' => [] }
  );
  _mt(ua => $ua)->print('/ip/firewall/nat', query => [ 'chain=srcnat' ]);

  is $ua->requests->[0]->uri->path, '/rest/ip/firewall/nat/print', 'path';
};

subtest 'a .query word list with a lone "#!" negation stays verbatim' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/interface/print' => [] }
  );
  _mt(ua => $ua)->print('/interface', query => [ 'type=ether', 'type=vlan', '#|!' ]);

  is $ua->requests->[0]->content, '{".query":["type=ether","type=vlan","#|!"]}',
    'vendor example, operator words untouched';
};

done_testing;
