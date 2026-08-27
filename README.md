# WWW::MikroTik

Simple Perl client for the [MikroTik RouterOS REST API](https://help.mikrotik.com/docs/spaces/ROS/pages/47579162/REST+API).

One Moo class, the console path as the API: what is `/ip/address` in the
RouterOS console is `$mt->list('/ip/address')` in Perl.

```perl
use WWW::MikroTik;

my $mt = WWW::MikroTik->new(
  host       => '192.168.88.1',
  user       => 'admin',
  password   => $ENV{MIKROTIK_PASSWORD},
  verify_ssl => 0,   # self-signed lab router
);

my $addrs = $mt->list('/ip/address', interface => 'ether2');
my $new   = $mt->add('/ip/address', address => '10.0.0.5/24', interface => 'ether2');
$mt->set('/ip/address', $new->{'.id'}, comment => 'uplink');
$mt->remove('/ip/address', $new->{'.id'});

my $pings = $mt->cmd('/ping', address => '10.0.0.1', count => '4');
```

All values are strings in both directions (`"disabled":"false"`, never a
JSON boolean), and `.id` looks like `*1A` and goes into the URL unencoded.

## Installation

```
cpanm WWW::MikroTik
```

## Status

Implemented and tested (mock-driven test suite, no router required). Not yet
released to CPAN — see `TODO.md` for the implementation history.

## License

Same terms as Perl itself. See `LICENSE`.
