#!/usr/bin/env perl
use strict;
use warnings;
use Test::More;
use Test::Fatal qw( exception );
use Log::Any::Test;
use Log::Any qw( $log );
use lib 't/lib';

use HTTP::Response;
use Scalar::Util qw( refaddr );
use Test::WWW::MikroTik::MockUA;
use WWW::MikroTik;

# The seam Net::Async::MikroTik builds on: request() is build_request(), the
# ua, and parse_response() in a row, and every verb returns exactly what
# request() returns. A subclass that overrides request() therefore swaps the
# transport for every verb and keeps their path/argument handling.

#### Test doubles

# A ua that must never be reached.
{
  package Test::Seam::NoUA;
  sub new     { bless { calls => 0 }, shift }
  sub calls   { $_[0]{calls} }
  sub request { $_[0]{calls}++; die 'Test::Seam::NoUA: the ua was called' }
}

# Overrides request() only, the way the async client will: records its
# arguments and returns one fixed marker object (a stand-in for a Future).
{
  package Test::Seam::Recorder;
  use Moo;
  extends 'WWW::MikroTik';
  has calls  => ( is => 'ro', default => sub { [] } );
  has marker => ( is => 'ro', default => sub { bless {}, 'Test::Seam::Marker' } );
  sub request {
    my ( $self, @args ) = @_;
    push @{ $self->calls }, [ @args ];
    return $self->marker;
  }
}

# Same, but returns a list - pins that the verbs pass request()'s list through.
{
  package Test::Seam::ListRecorder;
  use Moo;
  extends 'WWW::MikroTik';
  sub request { return ( 'first', 'second', 'third' ) }
}

# Re-implements request() from the two public halves around its own send,
# which is the shape of the async override (minus the Future).
{
  package Test::Seam::OwnSend;
  use Moo;
  extends 'WWW::MikroTik';
  has transport => ( is => 'ro', required => 1 );
  sub request {
    my ( $self, $method, $path, $body, %query ) = @_;
    my $req = $self->build_request($method, $path, $body, %query);
    return $self->parse_response($self->transport->request($req), $method, $path);
  }
}

sub _args {
  return (
    host     => 'router.example',
    user     => 'admin',
    password => 's3cr3t',
    @_
  );
}

sub _mt { WWW::MikroTik->new( _args( @_ ) ) }

sub _ua { Test::WWW::MikroTik::MockUA->new( routes => { @_ } ) }

sub _res {
  my ( $code, $message, $content ) = @_;
  return HTTP::Response->new( $code, $message, [ 'Content-Type' => 'application/json' ], $content );
}

my $base = 'https://router.example/rest';
my $auth = 'Basic YWRtaW46czNjcjN0';    # base64("admin:s3cr3t")

#### build_request

subtest 'build_request: the full request, without touching the ua' => sub {
  my $ua = Test::Seam::NoUA->new;
  my $mt = _mt( ua => $ua );

  my $req = $mt->build_request( 'PATCH', '/ip/address/*1A', { comment => 'uplink', disabled => 'false' },
    '.proplist' => [qw( address comment )], interface => 'ether2' );

  isa_ok $req, 'HTTP::Request';
  is $req->method, 'PATCH', 'method';
  is $req->uri->as_string,
    $base.'/ip/address/*1A?.proplist=address%2Ccomment&interface=ether2',
    'URL: base_url, path with a literal *, query sorted and form-encoded';
  is $req->header('Authorization'), $auth, 'Basic auth with user/password';
  is $req->header('Content-Type'), 'application/json', 'JSON content type';
  is $req->content, '{"comment":"uplink","disabled":"false"}', 'canonical JSON body bytes';
  is $ua->calls, 0, 'the ua was never called';
};

subtest 'build_request: no body, no content type, no content' => sub {
  my $ua = Test::Seam::NoUA->new;
  my $req = _mt( ua => $ua )->build_request( 'GET', 'interface', undef );

  is $req->method, 'GET', 'method';
  is $req->uri->as_string, $base.'/interface', 'leading slash added, no query';
  is $req->header('Authorization'), $auth, 'auth is there';
  is $req->header('Content-Type'), undef, 'no content type';
  is $req->content, '', 'empty content';
  is $ua->calls, 0, 'the ua was never called';
};

subtest 'build_request: an empty hashref body is still a body' => sub {
  my $req = _mt( ua => Test::Seam::NoUA->new )->build_request( 'POST', '/system/resource/print', {} );

  is $req->header('Content-Type'), 'application/json', 'JSON content type';
  is $req->content, '{}', 'the empty object';
};

subtest 'build_request: byte for byte what request() sends' => sub {
  my @calls = (
    [ 'GET',    '/ip/address',     undef, interface => 'ether2', '.proplist' => 'address' ],
    [ 'PUT',    '/ip/address',     { address => '10.0.0.5/24', comment => "B\x{fc}ro" } ],
    [ 'PATCH',  '/ip/address/*1A', { comment => 'x' } ],
    [ 'DELETE', '/ip/address/*1A' ],
    [ 'POST',   '/ping',           { address => '10.0.0.1', count => '4' } ]
  );
  my $ua = _ua( map { ( $_->[0].' /rest'.( $_->[1] =~ s/\?.*//r ) => [] ) } @calls );
  my $mt = _mt( ua => $ua );

  for my $call (@calls) {
    my $built = $mt->build_request(@$call);
    $mt->request(@$call);
    my $sent = $ua->requests->[-1];
    is $sent->as_string, $built->as_string, $call->[0].' '.$call->[1].': identical request';
  }
};

#### parse_response

subtest 'parse_response: decoded JSON, like request()' => sub {
  my $mt = _mt( ua => Test::Seam::NoUA->new );

  is_deeply $mt->parse_response( _res( 200, 'OK', '[{".id":"*1","disabled":"false"}]' ), 'GET', '/ip/address' ),
    [ { '.id' => '*1', disabled => 'false' } ], 'an array of records';
  is_deeply $mt->parse_response( _res( 200, 'OK', "{\".id\":\"*1\",\"comment\":\"B\xc3\xbcro\"}" ), 'GET', '/ip/address/*1' ),
    { '.id' => '*1', comment => "B\x{fc}ro" }, 'one record, UTF-8 decoded to characters';
};

subtest 'parse_response: an empty body is the empty list / undef' => sub {
  my $mt = _mt( ua => Test::Seam::NoUA->new );

  for my $res ( _res( 200, 'OK', '' ), _res( 204, 'No Content', '' ) ) {
    my @list = $mt->parse_response( $res, 'DELETE', '/ip/address/*1' );
    is scalar @list, 0, $res->code.': empty list in list context';
    my $scalar = $mt->parse_response( $res, 'DELETE', '/ip/address/*1' );
    is $scalar, undef, $res->code.': undef in scalar context';
  }
};

subtest 'parse_response: croaks exactly like request(), at its caller' => sub {
  my $file = __FILE__;
  my @cases = (
    [ 'router error',     _res( 404, 'Not Found', '{"detail":"no such item","error":404,"message":"Not Found"}' ),
      qr/\AWWW::MikroTik: 404 Not Found: no such item at / ],
    [ 'error, no detail', _res( 406, 'Not Acceptable', '{"error":406,"message":"Not Acceptable"}' ),
      qr/\AWWW::MikroTik: 406 Not Acceptable at / ],
    [ 'error, not JSON',  _res( 502, 'Bad Gateway', '<html>bad gateway</html>' ),
      qr/\AWWW::MikroTik: 502 Bad Gateway at / ],
    [ '2xx, not JSON',    _res( 200, 'OK', '<html>portal</html>' ),
      qr/\AWWW::MikroTik: 200 OK: response body is not JSON: \S/ ]
  );

  for my $case (@cases) {
    my ( $name, $res, $like ) = @$case;
    my $mt = _mt( ua => _ua( 'GET /rest/x' => $res ) );

    my $direct = exception { $mt->parse_response( $res, 'GET', '/x' ) }; my $line = __LINE__;
    like $direct, $like, $name.': message';
    like $direct, qr/ at \Q$file\E line $line\.\n\z/, $name.': reported at the caller';

    my $via = exception { $mt->request( 'GET', '/x' ) };
    my ( $d, $v ) = map { s/ at \S+ line \d+\.\n\z//r } $direct, $via;
    is $d, $v, $name.': same message as request()';
  }
};

#### The contract: every verb returns request()'s value untouched

subtest 'every verb returns what request() returns and passes the right arguments' => sub {
  my $ua = Test::Seam::NoUA->new;
  my $mt = Test::Seam::Recorder->new( _args( ua => $ua ) );

  my @verbs = (
    [ get    => [ '/ip/address', interface => 'ether2' ],
      [ 'GET', '/ip/address', undef, { interface => 'ether2' } ] ],
    [ get    => [ '/ip/address/*1A' ],
      [ 'GET', '/ip/address/*1A', undef, {} ] ],
    [ put    => [ '/ip/address', { address => '10.0.0.5/24' } ],
      [ 'PUT', '/ip/address', { address => '10.0.0.5/24' }, {} ] ],
    [ patch  => [ '/ip/address/*1A', { comment => 'x' } ],
      [ 'PATCH', '/ip/address/*1A', { comment => 'x' }, {} ] ],
    [ delete => [ '/ip/address/*1A' ],
      [ 'DELETE', '/ip/address/*1A', undef, {} ] ],
    [ post   => [ '/ping', { address => '10.0.0.1', count => '4' } ],
      [ 'POST', '/ping', { address => '10.0.0.1', count => '4' }, {} ] ],
    [ list   => [ '/ip/address', interface => 'ether2', dynamic => 'false' ],
      [ 'GET', '/ip/address', undef, { interface => 'ether2', dynamic => 'false' } ] ],
    [ add    => [ '/ip/address', address => '10.0.0.5/24', interface => 'ether2' ],
      [ 'PUT', '/ip/address', { address => '10.0.0.5/24', interface => 'ether2' }, {} ] ],
    [ set    => [ '/ip/address', '*1A', comment => 'uplink' ],
      [ 'PATCH', '/ip/address/*1A', { comment => 'uplink' }, {} ] ],
    [ set    => [ '/interface', 'vlan#1', comment => 'x' ],
      [ 'PATCH', '/interface/vlan%231', { comment => 'x' }, {} ] ],
    [ remove => [ '/ip/address', '*1A' ],
      [ 'DELETE', '/ip/address/*1A', undef, {} ] ],
    [ cmd    => [ '/system/resource/print' ],
      [ 'POST', '/system/resource/print', {}, {} ] ],
    [ cmd    => [ '/ping', address => '10.0.0.1', count => '4' ],
      [ 'POST', '/ping', { address => '10.0.0.1', count => '4' }, {} ] ],
    [ print  => [ '/interface', proplist => [qw( name type )], query => [ 'type=ether', 'type=vlan', '#|' ] ],
      [ 'POST', '/interface/print',
        { '.proplist' => [qw( name type )], '.query' => [ 'type=ether', 'type=vlan', '#|' ] }, {} ] ]
  );

  for my $verb (@verbs) {
    my ( $name, $args, $expect ) = @$verb;
    my $label = $name.'('.join( ', ', map { ref $_ ? ref $_ : "'".$_."'" } @$args ).')';

    @{ $mt->calls } = ();
    my $ret = $mt->$name(@$args);

    is refaddr $ret, refaddr $mt->marker, $label.' returns the very object request() returned';
    is scalar @{ $mt->calls }, 1, $label.' calls request() once';
    my ( $method, $path, $body, @query ) = @{ $mt->calls->[0] };
    is_deeply [ $method, $path, $body, { @query } ], $expect, $label.' passes method, path, body, query';
  }

  is $ua->calls, 0, 'with request() overridden, the ua is never called';
};

subtest 'list context: every verb passes request()\'s list through' => sub {
  my $mt = Test::Seam::ListRecorder->new( _args( ua => Test::Seam::NoUA->new ) );

  my %args = (
    get => [ '/x' ], put => [ '/x', {} ], patch => [ '/x', {} ], delete => [ '/x' ],
    post => [ '/x', {} ], list => [ '/x' ], add => [ '/x' ], set => [ '/x', '*1' ],
    remove => [ '/x', '*1' ], cmd => [ '/x' ], print => [ '/x' ]
  );
  for my $name ( sort keys %args ) {
    my @ret = $mt->$name( @{ $args{$name} } );
    is_deeply \@ret, [qw( first second third )], $name;
  }
};

subtest 'request() rebuilt from build_request + parse_response behaves like request()' => sub {
  my $transport = _ua(
    'GET /rest/ip/address'     => [ { '.id' => '*1' } ],
    'PATCH /rest/interface/vlan%231' => { name => 'vlan#1' },
    'DELETE /rest/ip/address/*1' => HTTP::Response->new(204),
    'GET /rest/missing'        => { error => 404, message => 'Not Found' }
  );
  my $mt = Test::Seam::OwnSend->new( _args( ua => Test::Seam::NoUA->new, transport => $transport ) );
  my $file = __FILE__;

  is_deeply $mt->list( '/ip/address', interface => 'ether2' ), [ { '.id' => '*1' } ], 'list';
  is_deeply $mt->set( '/interface', 'vlan#1', comment => 'x' ), { name => 'vlan#1' }, 'set';
  is_deeply [ $mt->remove( '/ip/address', '*1' ) ], [], 'remove: empty list';
  my $err = exception { $mt->get('/missing') }; my $line = __LINE__;
  like $err, qr/\AWWW::MikroTik: 404 Not Found at \Q$file\E line $line\.\n\z/,
    'croak through the subclass is still reported at the caller';

  is $transport->requests->[0]->uri->as_string, $base.'/ip/address?interface=ether2', 'wire: list URL';
  is $transport->requests->[1]->content, '{"comment":"x"}', 'wire: set body';
};

#### Logging stays where it was

subtest 'build_request logs the two debug lines, masked; parse_response logs info' => sub {
  my $mt = _mt( ua => Test::Seam::NoUA->new );
  $log->clear;

  my $req = $mt->build_request( 'PUT', '/ppp/secret', { name => 'alice', password => 'hunter2' },
    token => 'abc' );

  my @msgs = @{ $log->msgs };
  is_deeply [ map { $_->{level} } @msgs ], [qw( debug debug )], 'two debug lines, nothing else';
  is $msgs[0]{message}, 'PUT '.$base.'/ppp/secret?token=***', 'request line, query secret masked';
  is $msgs[1]{message}, 'Body: {"name":"alice","password":"***"}', 'body, password masked';
  is $req->content, '{"name":"alice","password":"hunter2"}', 'the request itself is unmasked';

  $log->clear;
  $mt->parse_response( _res( 200, 'OK', '{".id":"*1"}' ), 'PUT', '/ppp/secret' );
  is_deeply [ map { [ $_->{level}, $_->{message} ] } @{ $log->msgs } ],
    [ [ info => 'PUT /ppp/secret -> 200' ] ], 'parse_response: one info line';

  $log->clear;
  exception { $mt->parse_response( _res( 404, 'Not Found', '{"error":404,"message":"Not Found"}' ), 'GET', '/x' ) };
  is_deeply [ map { [ $_->{level}, $_->{message} ] } @{ $log->msgs } ],
    [ [ info => 'GET /x -> 404' ], [ error => 'WWW::MikroTik: 404 Not Found' ] ],
    'parse_response on an error: info, then the croak message at error';
};

done_testing;
