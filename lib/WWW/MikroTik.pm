package WWW::MikroTik;

# ABSTRACT: Simple Perl client for the MikroTik RouterOS REST API

use Moo;
use Carp qw( croak );
use HTTP::Request;
use JSON::MaybeXS;
use Log::Any qw( $log );
use LWP::UserAgent;
use Types::Standard qw( Bool Enum Int Maybe Str );
use URI;
use namespace::clean;

our $VERSION = '0.001';

=head1 SYNOPSIS

    use WWW::MikroTik;

    my $mt = WWW::MikroTik->new(
      host       => '192.168.88.1',
      user       => 'admin',
      password   => $ENV{MIKROTIK_PASSWORD},
      verify_ssl => 0,                    # lab router, self-signed
    );

    my $addrs = $mt->list('/ip/address', interface => 'ether2');
    my $new   = $mt->add('/ip/address', address => '10.0.0.5/24', interface => 'ether2');
    $mt->set('/ip/address', $new->{'.id'}, comment => 'uplink');
    $mt->remove('/ip/address', $new->{'.id'});

    my ($res) = @{ $mt->cmd('/system/resource/print') };
    my $pings = $mt->cmd('/ping', address => '10.0.0.1', count => '4');
    my $ifs   = $mt->print('/interface', proplist => [qw( name type )],
                           query => [ 'type=ether', 'type=vlan', '#|' ]);

=head1 DESCRIPTION

Thin wrapper around the RouterOS REST API (C<https://E<lt>routerE<gt>/rest>),
available from RouterOS 7.1. The console path is the API surface: C</ip/address>
in the console is C<GET /rest/ip/address> on the wire and C<< $mt->get('/ip/address') >>
here. RouterOS console commands map onto this module one for one:

    Perl method      HTTP method            Console command
    ---------------  ---------------------  -----------------------------
    list / get       GET                    print
    add / put        PUT                    add
    set / patch      PATCH                  set
    remove / delete  DELETE                 remove
    cmd / post       POST                   any command word
    print            POST to $path/print    print (POST form, for .query)

The left-hand name of each pair is the RouterOS-flavored method (flat
C<< key => value >> arguments, the record C<.id> as its own argument), the
right-hand one the plain HTTP verb underneath (full path, hashref body). All
of them go through L</request>.

Every RouterOS value is a string in both directions - C<"disabled":"false">,
C<"cpu-count":"16">. This module does not convert anything, in either direction:
compare with C<eq> and send C<'true'>/C<'false'>, never JSON booleans.

Failures from status 400 upwards C<croak> with
C<< WWW::MikroTik: <status> <message>: <detail> >> - the fields of the
router's JSON error object (C<: E<lt>detailE<gt>> is left out when the router
sends none). A failure without such an object - a body that is not JSON or has
no C<message>, or a connection that never got an answer (LWP reports an
unreachable router or a TLS error as a synthetic C<500> response) - croaks
with the HTTP status line instead: C<< WWW::MikroTik: <status line> >>. A successful status with a
body that is not JSON (a captive portal, a proxy's HTML page) croaks with
C<< WWW::MikroTik: <status line>: response body is not JSON: <reason> >>.
There is no error class; catch with C<eval> or L<Try::Tiny>.

Logging goes through L<Log::Any>: the request line and the JSON request body
at C<debug>, C<< <method> <path> -> <status> >> at C<info>, the croak message
at C<error>. In those two C<debug> lines the value of every top-level body key
and every query parameter whose name contains C<password>, C<passphrase>,
C<secret>, C<pre-shared-key>, C<preshared-key> or C<private-key> (in any
case) is replaced by C<***>; the request sent to the router is unchanged.
The debug lines are only built when the logger has C<debug> enabled.
Everything else is logged as sent: a secret under any other name, one inside
a nested structure or a C<.query> word (C<password=...>), or one in the
path. The Basic auth credentials and successful response bodies are never
logged; the C<error> line carries the router's error text and, for a
non-JSON body, the decoder's reason, which may quote the start of that body.

=cut

#### Attributes

has host => (
  is       => 'ro',
  isa      => Str,
  required => 1,
);

=attr host

Router address - IP or hostname. Required.

=cut

has user => (
  is      => 'ro',
  isa     => Str,
  default => sub { 'admin' },
);

=attr user

Console user for HTTP Basic auth. Defaults to C<admin>.

=cut

has password => (
  is      => 'ro',
  isa     => Str,
  default => sub { '' },
);

=attr password

Console password for HTTP Basic auth. Defaults to C<''>, RouterOS's own
default for a fresh C<admin> account.

=cut

has scheme => (
  is      => 'ro',
  isa     => Enum[qw( https http )],
  default => sub { 'https' },
);

=attr scheme

C<https> or C<http>. Defaults to C<https> (RouterOS's C<www-ssl> service,
on by default). C<http> only works from RouterOS 7.9 onward and sends the
Basic auth password in clear - use it on a trusted lab network only.

=cut

has port => (
  is  => 'ro',
  isa => Maybe[Int],
);

=attr port

TCP port. Leave unset to use the scheme's standard port (443 for C<https>,
80 for C<http>); set it only when the router's REST service listens
elsewhere.

=cut

has verify_ssl => (
  is      => 'ro',
  isa     => Bool,
  default => sub { 1 },
);

=attr verify_ssl

    verify_ssl => 0,   # lab router, self-signed cert

Verify the router's TLS certificate. Defaults to C<1>. Set it to C<0> only
for a lab router with a self-signed certificate - leave it at the default
against anything reachable from an untrusted network.

=cut

has timeout => (
  is      => 'ro',
  isa     => Int,
  default => sub { 60 },
);

=attr timeout

LWP request timeout in seconds, passed to C<ua>'s constructor. Defaults to
C<60>, matching the router's own request timeout (see L</cmd>) - but
this is this client's socket timeout, enforced independently of whatever
the router does on its end.

=cut

has base_url => (
  is  => 'lazy',
  isa => Str,
);

sub _build_base_url {
  my ( $self ) = @_;
  return $self->scheme.'://'.$self->host
    .( defined $self->port ? ':'.$self->port : '' ).'/rest';
}

=attr base_url

Lazily built from C<scheme>, C<host> and C<port>:
C<< <scheme>://<host>[:<port>]/rest >>. Every request path is appended to
this.

=cut

has ua => ( is => 'lazy' );

sub _build_ua {
  my ( $self ) = @_;
  return LWP::UserAgent->new(
    agent    => 'WWW-MikroTik/'.$VERSION,
    timeout  => $self->timeout,
    ssl_opts => {
      verify_hostname => $self->verify_ssl ? 1 : 0,
      SSL_verify_mode => $self->verify_ssl ? 1 : 0,
    },
  );
}

=attr ua

Lazily built L<LWP::UserAgent>. This is the extension seam: anything that
responds to C<< ->request($http_request) >> with an L<HTTP::Response> works
here in its place - which is how the test suite runs the whole client
against a mock user agent without ever touching a router.

C<timeout> and C<verify_ssl> are only applied when this default is built; an
object passed in as C<ua> is used exactly as it is.

=cut

has _json => ( is => 'lazy' );

sub _build__json { JSON::MaybeXS->new( canonical => 1, convert_blessed => 1, utf8 => 1 ) }

#### Core

sub request {
  my ( $self, $method, $path, $body, %query ) = @_;
  my $uri = $self->_uri($path, %query);
  my $req = HTTP::Request->new($method => $uri);
  $req->authorization_basic($self->user, $self->password);
  $log->debug($method.' '.$self->_uri($path, %{ $self->_masked({ %query }) })->as_string)
    if $log->is_debug;
  if (defined $body) {
    $req->content_type('application/json');
    $req->content($self->_json->encode($body));
    $log->debug('Body: '.$self->_json->encode($self->_masked($body)))
      if $log->is_debug;
  }
  my $res = $self->ua->request($req);
  $log->info($method.' '.$path.' -> '.$res->code);
  $self->_croak_response($res) if $res->code >= 400;
  my $content = $res->content;
  return unless defined $content && length $content;
  my $data;
  return $data if eval { $data = $self->_json->decode($content); 1 };
  ( my $reason = $@ ) =~ s/\A(.*) at .+? line \d+\.?\s*\z/$1/s;
  $self->_croak($res->status_line.': response body is not JSON: '.$reason);
}

=method request

    my $decoded = $mt->request('GET', '/ip/address', undef, interface => 'ether2');

The method every verb below is a thin wrapper around. C<$method> is an HTTP
verb, C<$path> the RouterOS console path (a leading C</> is added if
missing), C<$body> a hashref to JSON-encode as the request body (or
C<undef> for none), and C<%query> becomes the URL query string - keys
sorted, an arrayref value joined with commas. Query keys and values are
form-encoded by L<URI> (C<,> goes out as C<%2C>, C</> as C<%2F>). RouterOS
decodes these as expected: a C<.proplist> sent as C<address%2Cinterface>
returned only the requested keys, and a filter on C<address=10.0.0.1/24> sent
with C<%2F> matched exactly that record (confirmed against RouterOS 7.18.2).
The path is not touched beyond what L<URI> escapes on its own, so a C<*>
stays a C<*>.

Sends HTTP Basic auth with C<user>/C<password> on every request. A response
status of 400 or higher C<croak>s with
C<< WWW::MikroTik: <status> <message>: <detail> >>, read from the router's
JSON error object (C<detail> optional), or with
C<< WWW::MikroTik: <status line> >> when the response body is not a JSON
object with a C<message>. A status below 400 with a body that
does not decode as JSON C<croak>s with
C<< WWW::MikroTik: <status line>: response body is not JSON: <reason> >>.

Returns the decoded JSON response - an arrayref of records or a single
hashref, depending on the call. An empty response body is not an error: it
returns C<undef> in scalar context and the empty list in list context.

=cut

#### HTTP verbs

sub get {
  my ( $self, $path, %query ) = @_;
  return $self->request('GET', $path, undef, %query);
}

=method get

    my $addrs = $mt->get('/ip/address', interface => 'ether2');
    my $addr  = $mt->get('/ip/address/*1A');
    my $slim  = $mt->get('/ip/address', '.proplist' => [qw( address disabled )]);

C<< request('GET', $path, undef, %query) >>. C<list> is the RouterOS-flavored
alias for this same call. A menu path returns an arrayref of records; a path
ending in a record's C<.id> (or its name, on menus that accept one) returns
that one record as a hashref. C<.proplist> in C<%query> limits the fields
that come back - comma string or arrayref.

=cut

sub put {
  my ( $self, $path, $data ) = @_;
  return $self->request('PUT', $path, $data);
}

=method put

    my $rec = $mt->put('/ip/address', { address => '10.0.0.5/24', interface => 'ether2' });

C<< request('PUT', $path, $data) >> - creates a record. This is the HTTP
verb behind C<add>.

=cut

sub patch {
  my ( $self, $path, $data ) = @_;
  return $self->request('PATCH', $path, $data);
}

=method patch

    my $rec = $mt->patch('/ip/address/*1A', { comment => 'uplink' });

C<< request('PATCH', $path, $data) >> - updates a record. This is the HTTP
verb behind C<set>.

=cut

sub delete {
  my ( $self, $path ) = @_;
  return $self->request('DELETE', $path);
}

=method delete

    $mt->delete('/ip/address/*1A');

C<< request('DELETE', $path) >> - removes a record. This is the HTTP verb
behind C<remove>.

=cut

sub post {
  my ( $self, $path, $data ) = @_;
  return $self->request('POST', $path, $data);
}

=method post

    my $result = $mt->post('/ping', { address => '10.155.101.1', count => '4' });

C<< request('POST', $path, $data) >> - runs a console command. This is the
HTTP verb behind C<cmd>. A C<POST> with a record body against a plain menu
path (instead of a command) is a 406 from the router, not a validation
error here: C<PUT> creates, C<POST> runs a command.

=cut

#### RouterOS verbs

sub list {
  my ( $self, $path, %filter ) = @_;
  return $self->get($path, %filter);
}

=method list

    my $addrs = $mt->list('/ip/address', interface => 'ether3');

C<get($path, %filter)> - console C<print>. C<%filter> becomes the query
string and its conditions are ANDed. Every value in the result is a
string - C<< $addrs->[0]{disabled} >> comes back as C<"false">, never a
JSON boolean; compare with C<eq>.

=cut

sub add {
  my ( $self, $path, %data ) = @_;
  return $self->put($path, { %data });
}

=method add

    my $rec = $mt->add('/ip/address', address => '10.0.0.5/24', interface => 'ether2');

C<put($path, \%data)> - console C<add>. Returns the created record,
including its new C<.id> (C<*> followed by hex, e.g. C<*1A>) - pass that
value on to C<set>/C<remove> exactly as given, never URL-encoded. Send only
strings in C<%data> (C<< disabled => 'true' >>, not a JSON boolean) - the
router rejects anything else.

=cut

sub set {
  my ( $self, $path, $id, %data ) = @_;
  return $self->patch($path.'/'.$id, { %data });
}

=method set

    $mt->set('/ip/address', $rec->{'.id'}, comment => 'uplink');

C<< patch("$path/$id", \%data) >> - console C<set>. C<$id> is the record's
C<.id> (C<*1A>) or, on menus that accept it, its name; it goes into the URL
path exactly as given - URL-encoding the leading C<*> turns a normal
request into a 404 that looks like "record not found". Returns the full
updated record, not just the changed fields, with the same
all-values-are-strings contract as C<list>.

=cut

sub remove {
  my ( $self, $path, $id ) = @_;
  return $self->delete($path.'/'.$id);
}

=method remove

    $mt->remove('/ip/address', $rec->{'.id'});

C<< delete("$path/$id") >> - console C<remove>. C<$id> is the C<.id>
(C<*1A>), used unencoded exactly as under C<set>. Returns nothing on
success.

=cut

sub cmd {
  my ( $self, $path, %args ) = @_;
  return $self->post($path, { %args });
}

=method cmd

    my $pings = $mt->cmd('/ping', address => '10.155.101.1', count => '4');

C<post($path, \%args)> - console: any command word, not only C<print>.
C<%args> is always sent as a JSON object body, even when empty (C<{}>);
RouterOS accepts that for a command without arguments, e.g.
C<< $mt->cmd('/system/resource/print') >> (confirmed against RouterOS 7.18.2).

RouterOS enforces a 60 second limit on the underlying HTTP request itself
and does not stream output. A command with no natural end of its own -
C<ping> without C<count>, C<monitor> without C<once>, C<bandwidth-test>
without C<duration> - runs past that limit and comes back as a 400
"Session closed" instead of keeping the connection open. Always pass the
command's limiting parameter.

=cut

sub print {
  my ( $self, $path, %args ) = @_;
  my $proplist = delete $args{proplist};
  my $query    = delete $args{query};
  return $self->cmd($path.'/print',
    defined $proplist ? ( '.proplist' => $proplist ) : (),
    defined $query    ? ( '.query'    => $query    ) : (),
    %args,
  );
}

=method print

    my $ifs = $mt->print('/interface', proplist => [qw( name type )],
                         query => [ 'type=ether', 'type=vlan', '#|' ]);

C<< cmd("$path/print", %args) >> with C<proplist>/C<query> spelled out as
the dotted protocol keys C<.proplist>/C<.query> for you - this POST form is
the only way to use C<.query>. C<.query> is a stack, not an ANDed set of
conditions: push words, then C<#|> ORs the last two, C<#&> ANDs them, C<#!>
negates the last one; words with no operator between them are ANDed.
C<proplist> may be given as a comma string or as an arrayref - either
passes through unchanged.

=cut

#### Internals

sub _uri {
  my ( $self, $path, %query ) = @_;
  $path = '/'.$path unless $path =~ m{\A/};
  my $uri = URI->new($self->base_url.$path);
  $uri->query_form(map {
    ( $_ => ref $query{$_} eq 'ARRAY' ? join(',', @{$query{$_}}) : $query{$_} )
  } sort keys %query) if %query;
  return $uri;
}

sub _croak_response {
  my ( $self, $res ) = @_;
  my $error = eval { $self->_json->decode($res->content) };
  my $message = ref $error eq 'HASH' && defined $error->{message}
    ? $res->code.' '.$error->{message}
      .( defined $error->{detail} ? ': '.$error->{detail} : '' )
    : $res->status_line;
  $self->_croak($message);
}

sub _croak {
  my ( $self, $message ) = @_;
  $log->error('WWW::MikroTik: '.$message);
  croak 'WWW::MikroTik: '.$message;
}

# Copy of a request body or query hash for the debug log, with the values of
# password-like top-level keys replaced. Never what goes on the wire.
sub _masked {
  my ( $self, $data ) = @_;
  return $data unless ref $data eq 'HASH';
  return { map {
    ( $_ => /password|passphrase|secret|pre-?shared-key|private-key/i ? '***' : $data->{$_} )
  } keys %$data };
}

=seealso

=over 4

=item * L<RouterOS REST API|https://help.mikrotik.com/docs/spaces/ROS/pages/47579162/REST+API> - the vendor's own reference

=item * L<LWP::UserAgent> - the default HTTP client; see the C<ua> attribute to swap it out

=item * L<JSON::MaybeXS> - JSON encoding/decoding

=item * L<Log::Any> - this module's debug/info logging

=back

=cut

1;
