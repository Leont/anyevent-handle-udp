#! perl

use strict;
use warnings FATAL => 'all';
use Test::More tests => 3;
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
	my $server = AnyEvent::Handle::UDP->new(bind => [ localhost => 1383 ], on_recv => sub {
		my ($message, $handle, $client_addr) = @_;
		is($message, "Hello", "received \"Hello\"");
		$handle->push_send("World", $client_addr);
	});
	my $client = AnyEvent::Handle::UDP->new(connect => [ localhost => 1383 ], on_recv => $cb);
	$client->push_send("Hello");
	is($cb->recv, "World", 'received "World"');
}
