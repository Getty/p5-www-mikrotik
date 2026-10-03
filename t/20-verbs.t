#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use lib 't/lib';

use HTTP::Response;
use Test::WWW::MikroTik::MockUA;
use WWW::MikroTik;

# Each RouterOS verb maps to exactly one HTTP method and path shape. Getting
# add/set backwards (PUT vs PATCH) is a 406/404 from the real router, so each
# subtest asserts the method and path that actually left, not only the
# decoded return value.

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

subtest 'list -> GET, filters become the query string' => sub {
  my $addresses = [ { '.id' => '*2', 'actual-interface' => 'ether3', interface => 'ether3' } ];
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/ip/address' => $addresses }
  );
  my $mt = _mt(ua => $ua);

  my $result = $mt->list('/ip/address', interface => 'ether3');

  my $req = $ua->requests->[0];
  is $req->method, 'GET', 'list is GET';
  is $req->uri->as_string, 'https://router.example/rest/ip/address?interface=ether3',
    'filter became a query param';
  is $req->content, '', 'no body on a GET';
  is_deeply $result, $addresses, 'decoded list returned';
};

subtest 'add -> PUT, one record body, returns the created record' => sub {
  my $created = {
    '.id' => '*A', 'actual-interface' => 'dummy', address => '192.168.111.111/32',
    disabled => 'false', dynamic => 'false', interface => 'dummy', invalid => 'false',
    network => '192.168.111.111'
  };
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'PUT /rest/ip/address' => $created }
  );
  my $mt = _mt(ua => $ua);

  my $result = $mt->add('/ip/address', address => '192.168.111.111', interface => 'dummy');

  my $req = $ua->requests->[0];
  is $req->method, 'PUT', 'add is PUT, not POST';
  is $req->uri->path, '/rest/ip/address', 'no .id in the path for add';
  is $req->header('Content-Type'), 'application/json';
  is $req->content, '{"address":"192.168.111.111","interface":"dummy"}',
    'record body, canonical JSON';
  is_deeply $result, $created, 'the created record comes back';
};

subtest 'set -> PATCH by .id, returns the full updated record' => sub {
  my $updated = {
    '.id' => '*3', 'actual-interface' => 'dummy', address => '192.168.99.2/24',
    comment => 'test', disabled => 'false', dynamic => 'false', interface => 'dummy',
    invalid => 'false', network => '192.168.99.0'
  };
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'PATCH /rest/ip/address/*3' => $updated }
  );
  my $mt = _mt(ua => $ua);

  my $result = $mt->set('/ip/address', '*3', comment => 'test');

  my $req = $ua->requests->[0];
  is $req->method, 'PATCH', 'set is PATCH, not PUT';
  is $req->uri->path, '/rest/ip/address/*3', '.id appended to the path';
  is $req->content, '{"comment":"test"}', 'only the changed field in the body';
  is_deeply $result, $updated, 'the full updated record comes back, not just the diff';
};

subtest 'remove -> DELETE by .id, empty body on success' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'DELETE /rest/ip/address/*9' => HTTP::Response->new(200) }
  );
  my $mt = _mt(ua => $ua);

  my $result = $mt->remove('/ip/address', '*9');

  my $req = $ua->requests->[0];
  is $req->method, 'DELETE', 'remove is DELETE';
  is $req->uri->path, '/rest/ip/address/*9', '.id appended to the path';
  is $req->content, '', 'remove sends no body';
  is $result, undef, 'nothing decoded from an empty response body';
};

subtest 'cmd -> POST, args become the JSON body' => sub {
  my $pings = [ { host => '10.155.101.1', received => '1', sent => '1' } ];
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/ping' => $pings }
  );
  my $mt = _mt(ua => $ua);

  my $result = $mt->cmd('/ping', address => '10.155.101.1', count => '4');

  my $req = $ua->requests->[0];
  is $req->method, 'POST', 'cmd is POST';
  is $req->uri->path, '/rest/ping', 'command path is the console path, unchanged';
  is $req->content, '{"address":"10.155.101.1","count":"4"}', 'command args as JSON body';
  is_deeply $result, $pings, 'decoded command output returned';
};

subtest 'cmd with no args still sends a JSON object body' => sub {
  my $resource = [ { 'cpu-count' => '16', platform => 'MikroTik', version => '7.1beta4 (development)' } ];
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/system/resource/print' => $resource }
  );
  my $mt = _mt(ua => $ua);

  my $result = $mt->cmd('/system/resource/print');

  my $req = $ua->requests->[0];
  is $req->method, 'POST';
  is $req->header('Content-Type'), 'application/json',
    'a body (even an empty one) is always sent for cmd, unlike the bodiless curl in the vendor doc';
  is $req->content, '{}', 'no args -> an empty JSON object, not an omitted body';
  is_deeply $result, $resource;
};

subtest 'print -> POST to $path/print' => sub {
  my $ifs = [ { name => 'ether1', type => 'ether' } ];
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/interface/print' => $ifs }
  );
  my $mt = _mt(ua => $ua);

  my $result = $mt->print('/interface');

  my $req = $ua->requests->[0];
  is $req->method, 'POST', 'print is POST, same as any other command';
  is $req->uri->path, '/rest/interface/print', '/print appended to the menu path';
  is $req->content, '{}', 'no proplist/query given -> empty object body';
  is_deeply $result, $ifs;
};

subtest 'get -> GET, query string, no body; by .id returns one record' => sub {
  my $address = { '.id' => '*1A', address => '10.0.0.111/24', disabled => 'false' };
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => {
      'GET /rest/ip/address'     => [ $address ],
      'GET /rest/ip/address/*1A' => $address
    }
  );
  my $mt = _mt(ua => $ua);

  is_deeply $mt->get('/ip/address', network => '10.155.101.0', dynamic => 'true'), [ $address ],
    'list result';
  is_deeply $mt->get('/ip/address/*1A'), $address, 'single record';
  $mt->get('/ip/address', '.proplist' => [ 'address', 'disabled' ]);

  my @req = @{ $ua->requests };
  is $req[0]->method, 'GET', 'GET';
  is $req[0]->uri->as_string,
    'https://router.example/rest/ip/address?dynamic=true&network=10.155.101.0', 'filter URL';
  is $req[1]->uri->as_string, 'https://router.example/rest/ip/address/*1A', '.id literal';
  is $req[2]->uri->as_string,
    'https://router.example/rest/ip/address?.proplist=address%2Cdisabled', '.proplist URL';
  is $_->content, '', 'no body' for @req;
  ok !defined $_->header('Content-Type'), 'no Content-Type' for @req;
  is $_->header('Authorization'), 'Basic YWRtaW46czNjcjN0', 'Basic auth' for @req;
};

subtest 'list with no filter: bare URL, GET, no body' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/interface' => [ { '.id' => '*1', name => 'ether1' } ] }
  );
  my $mt = _mt(ua => $ua);

  is_deeply $mt->list('/interface'), [ { '.id' => '*1', name => 'ether1' } ], 'result';
  my $req = $ua->requests->[0];
  is $req->method, 'GET', 'GET';
  is $req->uri->as_string, 'https://router.example/rest/interface', 'no query string';
  is $req->content, '', 'no body';
};

subtest 'list with several filters: sorted, ANDed in the query' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/ip/address' => [] }
  );
  _mt(ua => $ua)->list('/ip/address', network => '10.155.101.0', dynamic => 'true');

  is $ua->requests->[0]->uri->as_string,
    'https://router.example/rest/ip/address?dynamic=true&network=10.155.101.0';
};

subtest 'put -> PUT with the hashref as body' => sub {
  my $created = { '.id' => '*A', address => '192.168.111.111/32', interface => 'dummy' };
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'PUT /rest/ip/address' => $created }
  );
  my $mt = _mt(ua => $ua);

  my $result = $mt->put('/ip/address', { interface => 'dummy', address => '192.168.111.111' });

  my $req = $ua->requests->[0];
  is $req->method, 'PUT', 'PUT';
  is $req->uri->as_string, 'https://router.example/rest/ip/address', 'URL';
  is $req->header('Content-Type'), 'application/json', 'Content-Type';
  is $req->header('Authorization'), 'Basic YWRtaW46czNjcjN0', 'Basic auth';
  is $req->content, '{"address":"192.168.111.111","interface":"dummy"}', 'canonical body';
  is_deeply $result, $created, 'created record';
};

subtest 'patch -> PATCH with the hashref as body, path as given' => sub {
  my $updated = { '.id' => '*3', comment => 'test' };
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'PATCH /rest/ip/address/*3' => $updated }
  );
  my $mt = _mt(ua => $ua);

  my $result = $mt->patch('/ip/address/*3', { comment => 'test' });

  my $req = $ua->requests->[0];
  is $req->method, 'PATCH', 'PATCH';
  is $req->uri->as_string, 'https://router.example/rest/ip/address/*3', 'URL';
  is $req->header('Content-Type'), 'application/json', 'Content-Type';
  is $req->header('Authorization'), 'Basic YWRtaW46czNjcjN0', 'Basic auth';
  is $req->content, '{"comment":"test"}', 'body';
  is_deeply $result, $updated, 'updated record';
};

subtest 'delete -> DELETE, no body, no Content-Type' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'DELETE /rest/ip/address/*9' => HTTP::Response->new(204) }
  );
  my $mt = _mt(ua => $ua);

  my $result = $mt->delete('/ip/address/*9');

  my $req = $ua->requests->[0];
  is $req->method, 'DELETE', 'DELETE';
  is $req->uri->as_string, 'https://router.example/rest/ip/address/*9', 'URL';
  is $req->content, '', 'no body';
  ok !defined $req->header('Content-Type'), 'no Content-Type';
  is $req->header('Authorization'), 'Basic YWRtaW46czNjcjN0', 'Basic auth';
  is $result, undef, 'nothing returned';
};

subtest 'post -> POST with the hashref as body' => sub {
  my $pings = [ { host => '10.155.101.1', received => '1', sent => '1' } ];
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'POST /rest/ping' => $pings }
  );
  my $mt = _mt(ua => $ua);

  my $result = $mt->post('/ping', { count => '4', address => '10.155.101.1' });

  my $req = $ua->requests->[0];
  is $req->method, 'POST', 'POST';
  is $req->uri->as_string, 'https://router.example/rest/ping', 'URL';
  is $req->header('Content-Type'), 'application/json', 'Content-Type';
  is $req->header('Authorization'), 'Basic YWRtaW46czNjcjN0', 'Basic auth';
  is $req->content, '{"address":"10.155.101.1","count":"4"}', 'canonical body';
  is_deeply $result, $pings, 'decoded output';
};

subtest 'put/patch/post without data: undef body, no Content-Type' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => {
      'PUT /rest/a' => {}, 'PATCH /rest/a' => {}, 'POST /rest/a' => {}
    }
  );
  my $mt = _mt(ua => $ua);

  $mt->put('/a');
  $mt->patch('/a');
  $mt->post('/a');

  is $_->content, '', $_->method.' sends no body' for @{ $ua->requests };
  ok !defined $_->header('Content-Type'), $_->method.' sends no Content-Type'
    for @{ $ua->requests };
};

subtest 'add / set / cmd with no data send an empty JSON object' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => {
      'PUT /rest/ip/address'     => { '.id' => '*B' },
      'PATCH /rest/ip/address/*B' => { '.id' => '*B' },
      'POST /rest/system/reboot' => []
    }
  );
  my $mt = _mt(ua => $ua);

  $mt->add('/ip/address');
  $mt->set('/ip/address', '*B');
  $mt->cmd('/system/reboot');

  is_deeply [ map { $_->method } @{ $ua->requests } ], [ qw( PUT PATCH POST ) ], 'verbs';
  is $_->content, '{}', $_->method.' body is {}' for @{ $ua->requests };
  is $_->header('Content-Type'), 'application/json', $_->method.' has Content-Type'
    for @{ $ua->requests };
};

subtest 'remove sends no body and no Content-Type' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'DELETE /rest/ip/address/*9' => HTTP::Response->new(200) }
  );
  _mt(ua => $ua)->remove('/ip/address', '*9');

  my $req = $ua->requests->[0];
  is $req->content, '', 'no body';
  ok !defined $req->header('Content-Type'), 'no Content-Type';
  is $req->header('Authorization'), 'Basic YWRtaW46czNjcjN0', 'Basic auth';
};

subtest 'RouterOS verbs carry Basic auth and the right Content-Type' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => {
      'GET /rest/ip/address'      => [],
      'PUT /rest/ip/address'      => {},
      'PATCH /rest/ip/address/*1' => {},
      'DELETE /rest/ip/address/*1' => HTTP::Response->new(200),
      'POST /rest/ping'           => [],
      'POST /rest/interface/print' => []
    }
  );
  my $mt = _mt(ua => $ua);

  $mt->list('/ip/address');
  $mt->add('/ip/address', address => '10.0.0.5/24');
  $mt->set('/ip/address', '*1', comment => 'x');
  $mt->remove('/ip/address', '*1');
  $mt->cmd('/ping', count => '1');
  $mt->print('/interface');

  my @has_body = ( 0, 1, 1, 0, 1, 1 );
  for my $i ( 0 .. 5 ) {
    my $req = $ua->requests->[$i];
    is $req->header('Authorization'), 'Basic YWRtaW46czNjcjN0', $req->method.' '.$req->uri->path.': auth';
    is defined $req->header('Content-Type') ? 1 : 0, $has_body[$i],
      $req->method.' '.$req->uri->path.': Content-Type iff body';
  }
};

subtest 'default user and password: admin and empty' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new(
    routes => { 'GET /rest/system/resource' => {} }
  );
  my $mt = WWW::MikroTik->new( host => 'router.example', ua => $ua );
  $mt->list('/system/resource');

  my ( $user, $password ) = $ua->requests->[0]->authorization_basic;
  is $user, 'admin', 'user';
  is $password, '', 'password';
};

done_testing;
