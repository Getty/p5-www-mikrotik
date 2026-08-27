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

done_testing;
