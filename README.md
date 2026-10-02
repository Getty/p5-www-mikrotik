# WWW::MikroTik

Simple Perl client for the [MikroTik RouterOS REST API](https://help.mikrotik.com/docs/spaces/ROS/pages/47579162/REST+API).

One Moo class on top of `LWP::UserAgent`, HTTP Basic auth, and the console
path as the API: what is `/ip/address` in the RouterOS console is
`$mt->list('/ip/address')` in Perl. No entity classes, no CLI, no value
conversion.

## Synopsis

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
my $pings = $mt->cmd('/ping', address => '10.0.0.1', count => '4');
my $ifs   = $mt->print('/interface', proplist => [qw( name type )],
                       query => [ 'type=ether', 'type=vlan', '#|' ]);
```

## Installation

```bash
cpanm WWW::MikroTik
```

From a checkout:

```bash
cpanm --installdeps .
prove -lr t/
```

## Constructor

| Attribute | Default | |
|---|---|---|
| `host` | required | Router address, IP or hostname |
| `user` | `admin` | Console user for HTTP Basic auth |
| `password` | `''` | Console password |
| `scheme` | `https` | `https` or `http` |
| `port` | scheme default | Set only when the REST service listens elsewhere |
| `verify_ssl` | `1` | `0` for a lab router with a self-signed certificate |
| `timeout` | `60` | LWP request timeout in seconds |
| `base_url` | built | `<scheme>://<host>[:<port>]/rest` |
| `ua` | `LWP::UserAgent` | Anything with `request($http_request)` returning an `HTTP::Response` |

`timeout` and `verify_ssl` configure the default `ua`; a `ua` you pass in is
used as it is.

## Methods

| Perl method | HTTP | Console |
|---|---|---|
| `list($path, %filter)` / `get($path, %query)` | `GET` | `print` |
| `add($path, %data)` / `put($path, \%data)` | `PUT` | `add` |
| `set($path, $id, %data)` / `patch("$path/$id", \%data)` | `PATCH` | `set` |
| `remove($path, $id)` / `delete("$path/$id")` | `DELETE` | `remove` |
| `cmd($path, %args)` / `post($path, \%args)` | `POST` | any command word |
| `print($path, proplist => ..., query => ..., %args)` | `POST` to `$path/print` | `print` |
| `request($method, $path, $body, %query)` | any | the core every method above wraps |

### Reading

```perl
my $addrs = $mt->list('/ip/address');                         # arrayref of records
my $some  = $mt->list('/ip/address', interface => 'ether2');  # filters are ANDed
my $one   = $mt->get('/ip/address/*1A');                      # one record, a hashref
my $slim  = $mt->get('/ip/address', '.proplist' => [qw( address disabled )]);
```

### Writing

```perl
my $rec = $mt->add('/ip/address', address => '10.0.0.5/24', interface => 'ether2');
$rec    = $mt->set('/ip/address', $rec->{'.id'}, comment => 'uplink');  # full updated record
$mt->remove('/ip/address', $rec->{'.id'});                              # returns nothing
```

`add` is a `PUT`. A `POST` runs a console command; it does not create a record.

### Commands

```perl
my ($res) = @{ $mt->cmd('/system/resource/print') };
my $pings = $mt->cmd('/ping', address => '10.0.0.1', count => '4');
```

RouterOS cuts a REST request off after 60 seconds and does not stream, so a
command without a natural end needs its limiting parameter (`count` for
`ping`, `once` for `monitor`, `duration` for `bandwidth-test`).

### print with `.proplist` and `.query`

```perl
my $ifs = $mt->print('/interface',
  proplist => [qw( name type )],
  query    => [ 'type=ether', 'type=vlan', '#|' ],   # ether OR vlan
);
```

`proplist` and `query` are sent as `.proplist` and `.query`; any other
argument goes into the command body unchanged. `query` is a stack: words are
pushed, `#|` ORs the last two, `#&` ANDs them, `#!` negates the last one.

## Values and ids

Every value is a string in both directions — `"disabled":"false"`, never a
JSON boolean. The module converts nothing: compare with `eq`, send
`'true'`/`'false'`.

A record's `.id` looks like `*1A` and goes into the URL path exactly as
given, unencoded.

## Errors

A response status of 400 or higher croaks:

```perl
my $ok = eval { $mt->remove('/ip/address', '*9'); 1 };
warn $@ unless $ok;    # WWW::MikroTik: <status> <message>: <detail>
```

The message is `WWW::MikroTik: <status> <message>: <detail>`, taken from the
router's JSON error object (`: <detail>` is left out when there is none), or
`WWW::MikroTik: <status line>` when the response carries no such object
(a non-JSON body, or no answer at all: LWP reports an unreachable router or a
TLS failure as a synthetic `500`). A successful status
with a body that is not JSON croaks with
`WWW::MikroTik: <status line>: response body is not JSON: <reason>`. There is
no error class.

## Logging

Through `Log::Any`: request line and JSON request body at `debug`,
`<method> <path> -> <status>` at `info`, the croak message at `error`. In the
`debug` lines the value of a top-level body key or query parameter is
replaced by `***` when its name, in any case, contains `password`,
`passphrase`, `secret`, `token` or `psk`, or is `key` or ends in `-key`
(`private-key`, `pre-shared-key`, `auth-key`, `tcp-md5-key`, ...). The one
exception is `public-key`, which stays visible; look-alikes such as
`passthrough`, `keepalive` or `key-size` are not masked. The request itself is
sent unchanged. Secrets under names outside that rule (an SNMP community's
`name`, say), in nested values, in `.query` words or in the path are logged as
sent. Basic auth credentials and
successful response bodies are never logged; the `error` line carries the
router's error text and, for a non-JSON body, the decoder's reason, which may
quote the start of that body.

## Tests

The suite is mock-driven and needs no router:

```bash
prove -lr t/
```

`t/90-live.t` runs only against a router you name, and only makes read-only
calls (`/system/resource/print`, `/ip/address`):

```bash
MIKROTIK_TEST_HOST=192.168.88.1 \
MIKROTIK_TEST_USER=admin \
MIKROTIK_TEST_PASSWORD=secret \
MIKROTIK_TEST_VERIFY_SSL=0 \
  prove -l t/90-live.t
```

`MIKROTIK_TEST_USER` defaults to `admin`, `MIKROTIK_TEST_PASSWORD` to the
empty string and `MIKROTIK_TEST_VERIFY_SSL` to `0`.

`MIKROTIK_TEST_SCHEME` (`https` or `http`) and `MIKROTIK_TEST_PORT` are
optional and passed to the constructor as `scheme`/`port` only when set; unset,
the module defaults apply (`https` on the scheme's standard port). To reach a
router over plain `http` (RouterOS 7.9 or later, password sent in clear, lab
network only):

```bash
MIKROTIK_TEST_HOST=192.168.88.1 \
MIKROTIK_TEST_SCHEME=http \
  prove -l t/90-live.t
```

Against a RB1100AHx4 running RouterOS 7.18.2 over `http` on port 80, this
confirmed that RouterOS accepts the empty `{}` body `cmd` sends for an
argument-less command, and understands query values sent percent-encoded
(`.proplist` as `address%2Cinterface`, a filter value containing `/` as `%2F`).

## License

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself. See `LICENSE`.
