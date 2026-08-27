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

done_testing;
