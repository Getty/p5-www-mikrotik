#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Fatal qw( exception );
use lib 't/lib';

use LWP::UserAgent;
use Test::WWW::MikroTik::MockUA;
use WWW::MikroTik;

# Attribute defaults, type checks, base_url building and the lazily built
# default ua. Nothing here opens a socket: LWP::UserAgent->new does not
# connect, and requests only ever go to the mock.

subtest 'defaults' => sub {
  my $mt = WWW::MikroTik->new( host => 'router.example' );

  is $mt->host, 'router.example', 'host as given';
  is $mt->user, 'admin', 'user defaults to admin';
  is $mt->password, '', 'password defaults to the empty string';
  is $mt->scheme, 'https', 'scheme defaults to https';
  is $mt->port, undef, 'port is unset by default';
  is $mt->verify_ssl, 1, 'verify_ssl defaults on';
  is $mt->timeout, 60, 'timeout defaults to 60';
  is $mt->base_url, 'https://router.example/rest', 'base_url from scheme and host';
};

subtest 'base_url is built from scheme, host and port' => sub {
  is( WWW::MikroTik->new( host => 'r', scheme => 'http' )->base_url,
    'http://r/rest', 'http scheme' );
  is( WWW::MikroTik->new( host => 'r', port => 8443 )->base_url,
    'https://r:8443/rest', 'port added after the host' );
  is( WWW::MikroTik->new( host => '192.168.88.1', scheme => 'http', port => 80 )->base_url,
    'http://192.168.88.1:80/rest', 'an explicit port is kept even when it is the default one' );
};

subtest 'an explicit base_url wins and is used verbatim' => sub {
  my $mt = WWW::MikroTik->new(
    host     => 'ignored.example',
    scheme   => 'http',
    port     => 1,
    base_url => 'https://proxy.example:9443/routers/a/rest',
  );
  is $mt->base_url, 'https://proxy.example:9443/routers/a/rest',
    'scheme/host/port do not touch a given base_url';

  my $ua = Test::WWW::MikroTik::MockUA->new( routes => { 'GET /routers/a/rest/ip/address' => [] } );
  $mt = WWW::MikroTik->new(
    host     => 'ignored.example',
    ua       => $ua,
    base_url => 'https://proxy.example:9443/routers/a/rest',
  );
  $mt->get('/ip/address');
  is $ua->requests->[0]->uri->as_string,
    'https://proxy.example:9443/routers/a/rest/ip/address',
    'requests go to the given base_url';
};

subtest 'type checks croak' => sub {
  like exception { WWW::MikroTik->new },
    qr/Missing required arguments?: host/, 'host is required';
  ok exception { WWW::MikroTik->new( host => 'r', scheme => 'ftp' ) },
    'scheme must be https or http';
  ok exception { WWW::MikroTik->new( host => 'r', scheme => 'HTTPS' ) },
    'scheme is case sensitive';
  ok exception { WWW::MikroTik->new( host => 'r', port => 'eighty' ) },
    'port must be an integer';
  ok exception { WWW::MikroTik->new( host => 'r', port => '80.5' ) },
    'port must not be a fraction';
  ok exception { WWW::MikroTik->new( host => 'r', timeout => 'soon' ) },
    'timeout must be an integer';
  ok exception { WWW::MikroTik->new( host => 'r', verify_ssl => 'yes' ) },
    'verify_ssl must be a Bool';
  ok exception { WWW::MikroTik->new( host => [ 'r' ] ) },
    'host must be a string';
  is exception { WWW::MikroTik->new( host => 'r', port => undef ) }, undef,
    'port may be given as undef';
};

subtest 'default ua: LWP::UserAgent, built without a request' => sub {
  my $mt = WWW::MikroTik->new( host => 'router.example' );
  my $ua = $mt->ua;

  isa_ok $ua, 'LWP::UserAgent';
  is $ua->agent, 'WWW-MikroTik/'.$WWW::MikroTik::VERSION, 'agent carries the version';
  is $ua->timeout, 60, 'default timeout passed through';
  is $ua->ssl_opts('verify_hostname'), 1, 'verify_hostname on by default';
  is $ua->ssl_opts('SSL_verify_mode'), 1, 'SSL_verify_mode on by default';
  is $mt->ua, $ua, 'the ua is built once';
};

subtest 'default ua follows timeout and verify_ssl' => sub {
  my $mt = WWW::MikroTik->new( host => 'r', verify_ssl => 0, timeout => 5 );
  my $ua = $mt->ua;

  is $ua->timeout, 5, 'timeout passed to the ua';
  is $ua->ssl_opts('verify_hostname'), 0, 'verify_hostname off';
  is $ua->ssl_opts('SSL_verify_mode'), 0, 'SSL_verify_mode off';
};

subtest 'a custom ua is used as-is' => sub {
  my $mock = Test::WWW::MikroTik::MockUA->new( routes => { 'GET /rest/x' => [] } );
  my $mt = WWW::MikroTik->new( host => 'r', ua => $mock, timeout => 5, verify_ssl => 0 );

  is $mt->ua, $mock, 'the very same object';
  $mt->get('/x');
  is scalar @{ $mock->requests }, 1, 'requests go through it';

  my $lwp = LWP::UserAgent->new( timeout => 7, agent => 'mine/1' );
  $mt = WWW::MikroTik->new( host => 'r', ua => $lwp, timeout => 5, verify_ssl => 0 );
  is $mt->ua->timeout, 7, 'timeout of a given LWP ua is not overwritten';
  is $mt->ua->agent, 'mine/1', 'agent of a given LWP ua is not overwritten';
};

done_testing;
