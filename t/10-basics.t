#! perl

use strict;
use warnings FATAL => 'all';
use Test::More tests => 2;
use AnyEvent::Handle::UDP;
use IO::Socket::INET;

alarm 3;

{
	my $cb = AE::cv;
	my $server = AnyEvent::Handle::UDP->new(bind => [ localhost => 1382 ], on_recv => $cb);
	my $client = IO::Socket::INET->new(PeerHost => 'localhost', PeerPort => 1382, Proto => 'udp');
	send $client, "Hello", 0;
	is($cb->recv, "Hello", 'received "Hello"');
}

{
	my $cb = AE::cv;
	my $server = IO::Socket::INET->new(LocalHost => 'localhost', LocalPort => 1383, Proto => 'udp') or die $!;
	my $client = AnyEvent::Handle::UDP->new(connect => [ localhost => 1383 ], on_recv => $cb);
	send $client->fh, "Hello", 0;
	my $client_addr = recv $server, my ($message), 1500, 0 or die "Could not receive: $!";
	send $server, "World", 0, $client_addr or die "Could not send: $!";
	is($cb->recv, "World", 'received "World"');
}
