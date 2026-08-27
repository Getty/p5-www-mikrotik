package Test::WWW::MikroTik::MockUA;

# Router-free stand-in for the WWW::MikroTik 'ua' attribute. Duck-types
# LWP::UserAgent: the only method the client calls is request($http_request),
# so that's the only method this class implements.
#
# my $ua = Test::WWW::MikroTik::MockUA->new(
#   routes => {
#     'GET /rest/ip/address'       => [ { '.id' => '*1', ... } ],   # 200, JSON-encoded
#     'PUT /rest/ip/address'       => { '.id' => '*A', ... },
#     'DELETE /rest/ip/address/*9' => { error => 404, message => 'Not Found' }, # status from 'error'
#     'POST /rest/ip/address/*9'   => HTTP::Response->new(200),               # used as-is
#     'POST /rest/ping'            => sub { my $req = shift; ... },           # dynamic
#   },
# );
# my $mt = WWW::MikroTik->new( host => '...', ua => $ua );
# ...
# is $ua->requests->[0]->method, 'GET';   # every request seen, in order

use Moo;
use Carp qw( croak );
use Scalar::Util qw( blessed );
use JSON::MaybeXS;
use HTTP::Response;
use namespace::clean;

has routes => (
  is      => 'ro',
  default => sub { {} },
);

has requests => (
  is      => 'ro',
  default => sub { [] },
);

has _json => (
  is      => 'ro',
  default => sub { JSON::MaybeXS->new( canonical => 1, utf8 => 1 ) },
);

sub request {
  my ( $self, $req ) = @_;

  push @{ $self->requests }, $req;

  my $key = $req->method.' '.$req->uri->path;

  croak $self->_no_route_message( $key ) unless exists $self->routes->{ $key };

  return $self->_response_for( $self->routes->{ $key }, $req );
}

sub _response_for {
  my ( $self, $handler, $req ) = @_;

  $handler = $handler->( $req ) if ref $handler eq 'CODE';

  return $handler if blessed $handler && $handler->isa( 'HTTP::Response' );

  my $status = ref $handler eq 'HASH' && exists $handler->{error} ? $handler->{error} : 200;

  my $res = HTTP::Response->new( $status );
  $res->header( 'Content-Type' => 'application/json' );
  $res->content( $self->_json->encode( $handler ) );

  return $res;
}

sub _no_route_message {
  my ( $self, $key ) = @_;

  my @known = sort keys %{ $self->routes };

  return __PACKAGE__.": no mock route for '".$key."' (known routes: "
    .( @known ? join( ', ', @known ) : '(none)' ).')';
}

1;
