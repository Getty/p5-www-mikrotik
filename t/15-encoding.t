#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use Test::Fatal qw( exception );
use lib 't/lib';

use Encode qw( decode );
use HTTP::Response;
use JSON::MaybeXS;
use Test::WWW::MikroTik::MockUA;
use WWW::MikroTik;

binmode( $_, ':encoding(UTF-8)' ) for map { Test::More->builder->$_ } qw( output failure_output todo_output );

# What URI makes of query values and path segments, and what the JSON body
# looks like on the wire for non-ASCII data. The query expectations pin what
# URI produces today (form-encoding: ',' -> %2C, '/' -> %2F, ' ' -> '+').

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

sub _ua { Test::WWW::MikroTik::MockUA->new( routes => { @_ } ) }

my $base = 'https://router.example/rest';

#### Query values

subtest 'query values are form-encoded by URI' => sub {
  my @cases = (
    [ 'comma',        '10.0.0.1,10.0.0.2', '10.0.0.1%2C10.0.0.2' ],
    [ 'slash',        '10.0.0.1/24',       '10.0.0.1%2F24' ],
    [ 'space',        'my bridge',         'my+bridge' ],
    [ 'ampersand',    'a&b',               'a%26b' ],
    [ 'equals',       'a=b',               'a%3Db' ],
    [ 'plus',         '1+1',               '1%2B1' ],
    [ 'wide char',    "\x{4e2d}",          '%E4%B8%AD' ],
    [ 'asterisk',     '*1A',               '*1A' ],
  );
  for my $case (@cases) {
    my ( $name, $value, $encoded ) = @$case;
    my $ua = _ua( 'GET /rest/ip/address' => [] );
    _mt( ua => $ua )->list( '/ip/address', comment => $value );
    is $ua->requests->[0]->uri->as_string, $base.'/ip/address?comment='.$encoded,
      $name.' in a query value';
    my %back = $ua->requests->[0]->uri->query_form;
    is decode('UTF-8', $back{comment}), $value, $name.' decodes back to the value that was passed';
  }
};

subtest 'query keys are encoded too' => sub {
  my $ua = _ua( 'GET /rest/ip/address' => [] );
  _mt( ua => $ua )->list( '/ip/address', 'a&b' => '1' );
  is $ua->requests->[0]->uri->as_string, $base.'/ip/address?a%26b=1', 'ampersand in a key';
};

subtest 'UTF-8 in a query value goes out as UTF-8 percent-escapes' => sub {
  my $ua = _ua( 'GET /rest/interface' => [] );
  my $mt = _mt( ua => $ua );

  my $wide = "B\x{fc}\x{4e2d}";
  $mt->list( '/interface', comment => $wide );
  is $ua->requests->[0]->uri->as_string, $base.'/interface?comment=B%C3%BC%E4%B8%AD',
    'a character string with a wide character is UTF-8 encoded';

  my $flagged = 'Büro';
  utf8::upgrade($flagged);
  $mt->list( '/interface', comment => $flagged );
  is $ua->requests->[1]->uri->as_string, $base.'/interface?comment=B%C3%BCro',
    'a utf8-flagged "Büro" is UTF-8 encoded';
};

subtest 'the same text gives the same URL with or without the utf8 flag' => sub {
  my $ua = _ua( 'GET /rest/interface' => [] );
  my $mt = _mt( ua => $ua );

  my $flagged = "B\x{fc}ro";
  utf8::upgrade($flagged);
  my $plain = "B\x{fc}ro";
  utf8::downgrade($plain);

  $mt->list( '/interface', comment => $flagged );
  $mt->list( '/interface', comment => $plain );

  is $ua->requests->[1]->uri->as_string, $ua->requests->[0]->uri->as_string,
    'a Latin-1 character is the same character whatever its internal representation';
};

subtest '.proplist: arrayref and comma string give the same URL' => sub {
  my $ua = _ua( 'GET /rest/ip/address' => [] );
  my $mt = _mt( ua => $ua );

  $mt->list( '/ip/address', '.proplist' => [ 'address', 'interface' ] );
  $mt->list( '/ip/address', '.proplist' => 'address,interface' );

  is $ua->requests->[0]->uri->as_string,
    $base.'/ip/address?.proplist=address%2Cinterface', 'arrayref joined with commas, comma escaped';
  is $ua->requests->[1]->uri->as_string, $ua->requests->[0]->uri->as_string,
    'the comma string is the identical URL';
};

subtest 'an arrayref value on an ordinary key is joined with commas' => sub {
  my $ua = _ua( 'GET /rest/interface' => [] );
  _mt( ua => $ua )->list( '/interface', type => [ 'ether', 'vlan' ] );

  is $ua->requests->[0]->uri->as_string, $base.'/interface?type=ether%2Cvlan',
    'same joining as .proplist, no key is special';
};

subtest 'an empty-string value (flag style) stays in the query' => sub {
  my $ua = _ua( 'GET /rest/interface' => [] );
  _mt( ua => $ua )->list( '/interface', 'without-paging' => '' );

  is $ua->requests->[0]->uri->as_string, $base.'/interface?without-paging=',
    'key with an empty value';
};

subtest 'no query args: no question mark' => sub {
  my $ua = _ua( 'GET /rest/interface' => [] );
  _mt( ua => $ua )->list('/interface');

  is $ua->requests->[0]->uri->as_string, $base.'/interface', 'bare URL';
};

#### JSON body

subtest 'a body with non-ASCII characters is UTF-8 bytes on the wire' => sub {
  my $ua = _ua( 'PUT /rest/ip/address' => { '.id' => '*A' } );
  _mt( ua => $ua )->add( '/ip/address', comment => 'Büro 中', address => '10.0.0.5/24' );

  my $content = $ua->requests->[0]->content;
  is $content, "{\"address\":\"10.0.0.5/24\",\"comment\":\"B\xc3\xbcro \xe4\xb8\xad\"}",
    'raw bytes: ü is C3 BC, 中 is E4 B8 AD, no \\u escapes';
  ok !utf8::is_utf8($content), 'the content is a byte string';
  is_deeply decode_json($content), { address => '10.0.0.5/24', comment => 'Büro 中' },
    'decodes back to the characters';
};

subtest 'a UTF-8 response body decodes to Perl characters' => sub {
  my $res = HTTP::Response->new( 200, 'OK', [ 'Content-Type' => 'application/json' ],
    "[{\"\.id\":\"*1\",\"comment\":\"B\xc3\xbcro\"}]" );
  my $ua = _ua( 'GET /rest/ip/address' => $res );

  my $result = _mt( ua => $ua )->list('/ip/address');

  is $result->[0]{comment}, "B\x{fc}ro", 'comment is the character string "Büro"';
  is length $result->[0]{comment}, 4, 'four characters, not five bytes';
};

#### Path segments

subtest '*1A stays literal in every verb that takes a path or an id' => sub {
  my $ua = _ua(
    'GET /rest/ip/address/*1A'    => { '.id' => '*1A' },
    'PATCH /rest/ip/address/*1A'  => { '.id' => '*1A' },
    'DELETE /rest/ip/address/*1A' => HTTP::Response->new(200),
    'PUT /rest/ip/address/*1A'    => { '.id' => '*1A' },
    'POST /rest/ip/address/*1A'   => []
  );
  my $mt = _mt( ua => $ua );

  $mt->get('/ip/address/*1A');
  $mt->set( '/ip/address', '*1A', comment => 'x' );
  $mt->remove( '/ip/address', '*1A' );
  $mt->request( 'PUT', '/ip/address/*1A', {} );
  $mt->post( '/ip/address/*1A', {} );

  is $_->uri->as_string, $base.'/ip/address/*1A', $_->method.' keeps the literal *1A'
    for @{ $ua->requests };
  unlike $_->uri->as_string, qr/%2A/i, $_->method.' never has %2A'
    for @{ $ua->requests };
};

subtest 'a name with a space becomes %20 in the path' => sub {
  my $ua = _ua(
    'PATCH /rest/interface/my%20bridge'  => { name => 'my bridge' },
    'DELETE /rest/interface/my%20bridge' => HTTP::Response->new(200)
  );
  my $mt = _mt( ua => $ua );

  $mt->set( '/interface', 'my bridge', comment => 'x' );
  $mt->remove( '/interface', 'my bridge' );

  is $ua->requests->[0]->uri->path, '/rest/interface/my%20bridge', 'set';
  is $ua->requests->[1]->uri->path, '/rest/interface/my%20bridge', 'remove';
};

subtest 'request() keeps a "?" in a caller-built path' => sub {
  my $ua = _ua( 'GET /rest/ip/address' => [] );
  _mt( ua => $ua )->request( 'GET', '/ip/address?x=y', undef );

  my $req = $ua->requests->[0];
  is $req->uri->path, '/rest/ip/address', 'path ends before the ?';
  is $req->uri->query, 'x=y', 'the ? starts the query string';
  is $req->uri->as_string, $base.'/ip/address?x=y', 'full URL as given';
};

#### The id is ONE path segment in set and remove
#
# Intended contract: '#', '?' and '%' in the id are escaped (a '#' would
# otherwise start a fragment and a '?' a query, so the request would hit
# another record), '*' stays a literal '*'. Route keys use the escaped path.

my @segments = (
  [ 'hash',            'vlan#1',    'vlan%231' ],
  [ 'question mark',   'a?b',       'a%3Fb' ],
  [ 'percent',         '50%off',    '50%25off' ],
  [ 'pre-encoded star', '%2A1',     '%252A1' ],
  [ 'all three',       'a#b?c%d',   'a%23b%3Fc%25d' ],
  [ 'space',           'my bridge', 'my%20bridge' ],
  [ 'star with hash',  '*1#A',      '*1%23A' ],
);

for my $case (@segments) {
  my ( $name, $id, $escaped ) = @$case;

  subtest 'set: '.$name.' in the id is one path segment' => sub {
    my $ua = _ua( 'PATCH /rest/interface/'.$escaped => { name => 'x' } );
    my $mt = _mt( ua => $ua );

    my $err = exception { $mt->set( '/interface', $id, comment => 'x' ) };
    is $err, undef, 'the request hit the escaped route';
    my $req = $ua->requests->[0];
    is $req->method, 'PATCH', 'PATCH';
    is $req->uri->path, '/rest/interface/'.$escaped, 'id is escaped inside the path';
    is $req->uri->query, undef, 'no query string came out of the id';
    is $req->uri->fragment, undef, 'no fragment came out of the id';
    is $req->uri->as_string, $base.'/interface/'.$escaped, 'full URL';
    is $req->content, '{"comment":"x"}', 'body untouched';
  };

  subtest 'remove: '.$name.' in the id is one path segment' => sub {
    my $ua = _ua( 'DELETE /rest/interface/'.$escaped => HTTP::Response->new(200) );
    my $mt = _mt( ua => $ua );

    my $err = exception { $mt->remove( '/interface', $id ) };
    is $err, undef, 'the request hit the escaped route';
    my $req = $ua->requests->[0];
    is $req->method, 'DELETE', 'DELETE';
    is $req->uri->path, '/rest/interface/'.$escaped, 'id is escaped inside the path';
    is $req->uri->query, undef, 'no query string came out of the id';
    is $req->uri->fragment, undef, 'no fragment came out of the id';
    is $req->uri->as_string, $base.'/interface/'.$escaped, 'full URL';
    is $req->content, '', 'no body';
  };
}

subtest 'set/remove with "a?b=c": the ?b=c is not a query string' => sub {
  my $ua = Test::WWW::MikroTik::MockUA->new( routes => {
    'PATCH /rest/interface/a%3Fb=c'  => { name => 'x' },
    'DELETE /rest/interface/a%3Fb=c' => HTTP::Response->new(200)
  } );
  my $mt = _mt( ua => $ua );

  is exception { $mt->set( '/interface', 'a?b=c', comment => 'x' ) }, undef, 'set hit the escaped route';
  is exception { $mt->remove( '/interface', 'a?b=c' ) }, undef, 'remove hit the escaped route';

  for my $req ( @{ $ua->requests } ) {
    is $req->uri->query, undef, $req->method.': no query string';
    like $req->uri->path, qr{\A/rest/interface/a%3Fb(?:=|%3D)c\z},
      $req->method.': the whole id is the last path segment';
  }
};

subtest 'set/remove: the segment is the last one, the menu path is not escaped' => sub {
  my $ua = _ua(
    'PATCH /rest/ip/address/*1A'  => { '.id' => '*1A' },
    'DELETE /rest/ip/address/*1A' => HTTP::Response->new(200)
  );
  my $mt = _mt( ua => $ua );

  $mt->set( '/ip/address', '*1A', comment => 'x' );
  $mt->remove( '/ip/address', '*1A' );

  is $_->uri->path, '/rest/ip/address/*1A', $_->method.': slashes of the menu path stay'
    for @{ $ua->requests };
};

#### Non-ASCII in the path
#
# The path is a character string like the query and the body: a Latin-1
# character goes out as its UTF-8 escape whatever Perl's internal utf8 flag
# says (URI alone would give %FC for the unflagged and %C3%BC for the flagged
# form of the same text).

subtest 'get: the same path gives the same URL with or without the utf8 flag' => sub {
  my $ua = _ua( 'GET /rest/interface/B%C3%BCro' => { name => "B\x{fc}ro" } );
  my $mt = _mt( ua => $ua );

  my $flagged = "/interface/B\x{fc}ro";
  utf8::upgrade($flagged);
  my $plain = "/interface/B\x{fc}ro";
  utf8::downgrade($plain);

  is exception { $mt->get($flagged) }, undef, 'flagged path hit the UTF-8 route';
  is exception { $mt->get($plain) },   undef, 'unflagged path hit the UTF-8 route';
  is $_->uri->as_string, $base.'/interface/B%C3%BCro', 'UTF-8 escape in the path'
    for @{ $ua->requests };
};

subtest 'set/remove: a non-ASCII id is UTF-8 escaped, flag or no flag' => sub {
  my $ua = _ua(
    'PATCH /rest/interface/B%C3%BCro-%E4%B8%AD'  => { name => 'x' },
    'DELETE /rest/interface/B%C3%BCro-%E4%B8%AD' => HTTP::Response->new(200)
  );
  my $mt = _mt( ua => $ua );

  my $flagged = "B\x{fc}ro-\x{4e2d}";    # a wide char is always flagged
  my $latin1  = "B\x{fc}ro";
  utf8::downgrade($latin1);

  is exception { $mt->set( '/interface', $flagged, comment => 'x' ) }, undef, 'set hit the UTF-8 route';
  is exception { $mt->remove( '/interface', $flagged ) }, undef, 'remove hit the UTF-8 route';

  my $ua2 = _ua(
    'PATCH /rest/interface/B%C3%BCro'  => { name => 'x' },
    'DELETE /rest/interface/B%C3%BCro' => HTTP::Response->new(200)
  );
  my $mt2 = _mt( ua => $ua2 );
  is exception { $mt2->set( '/interface', $latin1, comment => 'x' ) }, undef,
    'set with an unflagged Latin-1 id hit the UTF-8 route';
  is exception { $mt2->remove( '/interface', $latin1 ) }, undef,
    'remove with an unflagged Latin-1 id hit the UTF-8 route';
  is $_->uri->path, '/rest/interface/B%C3%BCro', $_->method.': %C3%BC, not %FC'
    for @{ $ua2->requests };
};

done_testing;
