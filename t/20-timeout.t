#! perl

use strict;
use warnings FATAL => 'all';
use Test::More 0.89;
use Test::Exception;

use AnyEvent::Handle::UDP;
use IO::Socket::INET;

alarm 12;

{
	my $cb = AE::cv;
	my $cb2 = AE::cv;
	my $server = AnyEvent::Handle::UDP->new(
		on_recv => $cb, 
		timeout => 3,    on_timeout => sub { $cb->croak("Timeout") },
		rtimeout => 4.5, on_rtimeout => sub { $cb2->croak("Read Timeout") }
	);
	my $client = IO::Socket::INET->new(PeerHost => 'localhost', PeerPort => 1382, Proto => 'udp');
	my $start_time = AE::now;
	throws_ok { $cb->recv } qr/Timeout/, 'Receive throws a timeout';
	cmp_ok AE::now, '>=', $start_time + 3, 'Three seconds have passed';
	throws_ok { $cb2->recv } qr/Read Timeout/, 'Receive throws a timeout again';
	cmp_ok AE::now, '>=', $start_time + 4.5, '1.5 more seconds have passed';
}

done_testing;
