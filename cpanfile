requires 'Carp';
requires 'HTTP::Request';
requires 'JSON::MaybeXS';
requires 'Log::Any';
requires 'LWP::Protocol::https';
requires 'LWP::UserAgent';
requires 'Moo';
requires 'namespace::clean';
requires 'Types::Standard';
requires 'URI';

on test => sub {
  requires 'HTTP::Response';
  requires 'Scalar::Util';
  requires 'Test::Fatal';
  requires 'Test::More';
};
