#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;

# Optional, opt-in only: exercises a real router when the maintainer points
# MIKROTIK_TEST_HOST at one. Never set that variable here or widen what this
# file does - read-only calls only, no add/set/remove/cmd that changes state.

unless ( $ENV{MIKROTIK_TEST_HOST} ) {
  plan skip_all => 'set MIKROTIK_TEST_HOST (and optionally MIKROTIK_TEST_USER / '
    .'MIKROTIK_TEST_PASSWORD / MIKROTIK_TEST_VERIFY_SSL / MIKROTIK_TEST_SCHEME / '
    .'MIKROTIK_TEST_PORT) to run this against a real router';
}

use WWW::MikroTik;

my $mt = WWW::MikroTik->new(
  host       => $ENV{MIKROTIK_TEST_HOST},
  user       => $ENV{MIKROTIK_TEST_USER} // 'admin',
  password   => $ENV{MIKROTIK_TEST_PASSWORD} // '',
  verify_ssl => $ENV{MIKROTIK_TEST_VERIFY_SSL} // 0,
  ( $ENV{MIKROTIK_TEST_SCHEME} ? ( scheme => $ENV{MIKROTIK_TEST_SCHEME} ) : () ),
  ( $ENV{MIKROTIK_TEST_PORT}   ? ( port   => $ENV{MIKROTIK_TEST_PORT} )   : () ),
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

# karr card 6: _uri builds the query string with URI->query_form, so the comma
# joining an arrayref goes out as %2C (?.proplist=address%2Cinterface). This
# settles whether RouterOS accepts that form: if it does not, the call croaks
# or the records come back with every field instead of the two asked for.
subtest 'ip address list with an arrayref .proplist (card 6)' => sub {
  my @wanted    = qw( address interface );
  my $addresses = $mt->get('/ip/address', '.proplist' => [ @wanted ]);
  is ref $addresses, 'ARRAY', 'a GET with a comma-joined query value returns an arrayref';
  my %wanted = map { ( $_ => 1 ) } @wanted;
  # .id is tolerated: unsure whether RouterOS returns it regardless of .proplist
  my @extra  = grep { !$wanted{$_} && $_ ne '.id' } map { keys %$_ } @$addresses;
  is_deeply [ sort @extra ], [], 'records carry only the requested keys'
    or diag 'RouterOS ignored .proplist sent with %2C - see karr card 6';
};

# karr card 6, second half: a '/' in a query value goes out as %2F
# (?address=10.0.0.1%2F24). Filter on an address the router itself reported.
subtest 'ip address filter with a slash in the value (card 6)' => sub {
  my $addresses = $mt->get('/ip/address');
  my ( $known ) = grep { defined && m{/} } map { $_->{address} } @$addresses;
  plan skip_all => 'router reports no address with a prefix length' unless $known;
  my $found = $mt->get('/ip/address', address => $known);
  is ref $found, 'ARRAY', 'a GET with a slash in a query value returns an arrayref';
  ok scalar @$found, 'the filter matches at least one record'
    or diag 'RouterOS did not match a value sent with %2F - see karr card 6';
  is_deeply [ grep { $_->{address} ne $known } @$found ], [], 'and only records with that address';
};

done_testing;
