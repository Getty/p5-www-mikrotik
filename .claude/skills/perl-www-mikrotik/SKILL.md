---
name: perl-www-mikrotik
description: "Use when talking to a MikroTik / RouterOS router from Perl — WWW::MikroTik, the RouterOS REST API under /rest, .id values like *1A, .proplist / .query, print/add/set/remove over HTTP, or why every JSON value comes back as a string."
user-invocable: false
allowed-tools: Read, Grep, Glob
model: sonnet
---

# WWW::MikroTik — RouterOS REST API from Perl

RouterOS (7.1+) exposes its console command tree as JSON over HTTP at
`https://<router>/rest/<menu path>`. `WWW::MikroTik` is a thin Moo wrapper
around exactly that — one class, no entity objects, no CLI. The console path
*is* the API: `/ip/address` in the CLI is `GET /rest/ip/address` on the wire and
`$mt->get('/ip/address')` in Perl. Full wire reference with verbatim examples:
`references/rest-api.md` (read it when a request shape is in doubt).

## The verbs

| Perl | HTTP | Console | Body / result |
|---|---|---|---|
| `get($path, %query)` / `list` | `GET /rest<path>?k=v` | `print` | list of records; `?k=v` filters (AND), `.proplist=a,b` selects fields |
| `get("$path/$id")` | `GET /rest<path>/<.id or name>` | `print` one | one record |
| `add($path, %data)` | `PUT /rest<path>` | `add` | the created record |
| `set($path, $id, %data)` | `PATCH /rest<path>/<.id>` | `set` | the updated record (all fields) |
| `remove($path, $id)` | `DELETE /rest<path>/<.id>` | `remove` | empty body on success |
| `cmd($path, %args)` / `post` | `POST /rest<path>` | any command word | records (`!re`) as a list, `!done` data as an object, nothing as `[]` |

`print($path, proplist => [...], query => [...])` is `cmd("$path/print", ...)`
with the two dotted keys spelled for you — the POST form of `print` is the
only way to use `.query`.

**`PUT` creates, `POST` runs a command.** `POST /rest/ip/address` with a
record body is a 406 "no such command"; `add` is a `PUT`.

## Wire facts that shape the code

- **Auth is HTTP Basic** with the console user. `www-ssl` is on by default
  (self-signed cert → `verify_ssl => 0` for lab boxes, on for production);
  plain `www` on port 80 works from 7.9 but sends the password in clear.
- **Every value is a string.** `"disabled":"false"`, `"cpu-count":"16"`,
  `"uptime":"2d20h12m20s"`. No JSON booleans or numbers in a response, and the
  router accepts strings for everything on the way in. Send `"true"`/`"false"`,
  never `JSON->true`. Compare with `eq`, not `==`, unless the field is known
  numeric. The module does not convert either way — strings are the contract.
- **`.id` is `*` + hex** (`*1`, `*A`, `*1F`) and goes into the URL path
  unencoded: `/rest/ip/address/*A`. Interfaces and some other menus also
  accept the name: `/rest/interface/ether1`. An `.id` is stable until the
  record is removed; it is not an index.
- **Keys with a leading dot are protocol keys**: `.id`, `.proplist`, `.query`,
  `.section`. Everything else is a RouterOS property under its console name
  (`actual-interface`, `dst-address`) — hyphens, never underscores.
- **`.query` is a stack**, not a list of ANDed conditions: `["type=ether",
  "type=vlan", "#|"]` is "ether OR vlan"; `#!` negates, `#&` ands. Words push,
  `#` operators combine; without an operator the words are ANDed.
- **A flag parameter is an empty string**: `{"once":""}`, `{"compact":""}`.
- **Errors are JSON** `{"error":<http status>,"message":"…","detail":"…"}` with
  the same status on the HTTP line. 400 "Session closed" is a command that ran
  past the **60 s request timeout** — `ping` without `count`, `monitor`
  without `once`, `bandwidth-test` without `duration`. There is no streaming;
  every long-running command needs its limiting parameter.
- **A menu path is not validated client-side.** `get('/ip/adress')` is a 404
  from the router, nothing more helpful — check the console path first when a
  request 404s unexpectedly.

## Using the module

```perl
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
my $pings = $mt->cmd('/ping', address => '10.0.0.1', count => 4);
my $ifs   = $mt->print('/interface', proplist => [qw( name type )],
                       query => [ 'type=ether', 'type=vlan', '#|' ]);
```

`request($method, $path, $body, %query)` underneath does the URL join, JSON
encode/decode and the error croak; every verb is one line on top of it. The
HTTP client is the `ua` attribute — anything with an `LWP::UserAgent`-compatible
`request($http_request)` returning an `HTTP::Response`. Tests inject a mock
there; a different transport (async) would subclass and override `request`.

Failures `croak` with `WWW::MikroTik: <status> <message>: <detail>` — the
three fields of the router's error object. Catch with `eval`/`Try::Tiny`;
there is no error class in this distribution.

## Repo

`p5-www-mikrotik/` — `WWW::MikroTik` (Moo, `LWP::UserAgent`). The intended
design, the phase plan and the API digest live in `TODO.md`; once code exists
the code is the truth and `TODO.md` is history. Style reference:
`../p5-www-hetzner` (`WWW::Hetzner`) — same house, deliberately more
machinery than this distribution wants.
