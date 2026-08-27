use strict;
use warnings;
use Test::More;

# Optional, opt-in only: exercises a real router when the maintainer points
# MIKROTIK_TEST_HOST at one. Never set that variable here or widen what this
# file does - read-only calls only, no add/set/remove/cmd that changes state.

unless ( $ENV{MIKROTIK_TEST_HOST} ) {
  plan skip_all => 'set MIKROTIK_TEST_HOST (and optionally MIKROTIK_TEST_USER / '
    .'MIKROTIK_TEST_PASSWORD / MIKROTIK_TEST_VERIFY_SSL) to run this against a real router';
}

use WWW::MikroTik;

my $mt = WWW::MikroTik->new(
  host       => $ENV{MIKROTIK_TEST_HOST},
  user       => $ENV{MIKROTIK_TEST_USER} // 'admin',
  password   => $ENV{MIKROTIK_TEST_PASSWORD} // '',
  verify_ssl => $ENV{MIKROTIK_TEST_VERIFY_SSL} // 0
);

subtest 'system resource print' => sub {
  my ( $resource ) = @{ $mt->cmd('/system/resource/print') };
  ok $resource, 'got a resource record';
  ok exists $resource->{version}, 'record has a version field';
  ok exists $resource->{'cpu-count'}, 'record has a cpu-count field';
};

subtest 'ip address list' => sub {
  my $addresses = $mt->get('/ip/address');
  is ref $addresses, 'ARRAY', 'listing addresses returns an arrayref';
};

done_testing;
