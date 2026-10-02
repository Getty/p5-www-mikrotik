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

done_testing;
