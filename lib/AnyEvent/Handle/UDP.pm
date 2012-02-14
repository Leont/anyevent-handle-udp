package AnyEvent::Handle::UDP;
use strict;
use warnings FATAL => 'all';

use Moo;

use AnyEvent qw//;
use AnyEvent::Util qw/fh_nonblocking/;
use AnyEvent::Socket qw//;

use Carp qw/croak/;
use Const::Fast qw/const/;
use Errno qw/EAGAIN EWOULDBLOCK/;
use Scalar::Util qw/reftype looks_like_number/;
use Socket qw/SOL_SOCKET SO_REUSEADDR SOCK_DGRAM/;
use Symbol qw/gensym/;

use namespace::clean;

const my $default_recv_size => 1500;

has fh => (
	is => 'ro',
	default => sub { gensym() },
);

has _bind_addr => (
	is => 'ro',
	init_arg => 'bind',
	predicate => '_has_bind_addr',
);

has _connect_addr => (
	is => 'ro',
	init_arg => 'connect',
	predicate => '_has_connect_addr',
);

sub BUILD {
	my $self = shift;
	$self->bind_to($self->_bind_addr) if $self->_has_bind_addr;
	$self->connect_to($self->_connect_addr) if $self->_has_connect_addr;
	$self->_drained;
	return;
}

has on_recv => (
	is => 'rw',
	isa => sub { reftype($_[0]) eq 'CODE' },
	required => 1,
);

has on_drain => (
	is => 'rw',
	isa => sub { reftype($_[0]) eq 'CODE' },
	required => 0,
	predicate => '_has_on_drain',
	clearer => 'clear_on_drain',
	trigger => sub {
		my ($self, $callback) = @_;
		$self->_drained if not @{ $self->{buffers} };
	},
);

sub _drained {
	my $self = shift;
	$self->on_drain->($self) if $self->_has_on_drain
}

has on_error => (
	is => 'rw',
	isa => sub { reftype($_[0]) eq 'CODE' },
	predicate => '_has_error_handler',
);

has receive_size => (
	is => 'rw',
	isa => sub { int $_[0] eq $_[0] },
	default => sub { $default_recv_size },
);

has family => (
	is => 'ro',
	isa => sub { int $_[0] eq $_[0] },
	default => sub { 0 },
);

has _full => (
	is => 'rw',
	predicate => '_has_full',
);

sub bind_to {
	my ($self, $addr) = @_;
	if (ref $addr) {
		my ($host, $port) = @{$addr};
		_on_addr($self, $host, $port, sub {
			bind $self->{fh}, $_[0] or $self->_error(1, "Could not bind: $!");
			setsockopt $self->{fh}, SOL_SOCKET, SO_REUSEADDR, 1 or $self->_error($!, 1, "Couldn't set so_reuseaddr: $!");
		});
	}
	else {
		bind $self->{fh}, $addr or $self->_error(1, "Could not bind: $!");
		setsockopt $self->{fh}, SOL_SOCKET, SO_REUSEADDR, 1 or $self->_error(1, "Couldn't set so_reuseaddr: $!");
	}
	return;
}

sub connect_to {
	my ($self, $addr) = @_;
	if (ref $addr) {
		my ($host, $port) = @{$addr};
		_on_addr($self, $host, $port, sub { connect $self->{fh}, $_[0] or $self->_error(1, "Could not connect: $!") });
	}
	else {
		connect $self->{fh}, $addr or $self->_error(1, "Could not connect: $!")
	}
	return;
}

sub _on_addr {
	my ($self, $host, $port, $on_success) = @_;

	AnyEvent::Socket::resolve_sockaddr($host, $port, 'udp', $self->family, SOCK_DGRAM, sub {
		my @targets = @_;
		while (1) {
			my $target = shift @targets or $self->_error(1, "No such host '$host' or port '$port'");
	 
			my ($domain, $type, $proto, $sockaddr) = @{$target};
			my $full = join ':', $domain, $type, $proto;
			if ($self->_has_full) {
				return redo if $self->_full ne $full;
			}
			else {
				socket $self->fh, $domain, $type, $proto or redo;
				fh_nonblocking $self->fh, 1;
				$self->_full($full);
			}

			$on_success->($sockaddr);

			$self->{reader} = AE::io $self->fh, 0, sub {
				while (defined (my $addr = recv $self->fh, my ($buffer), $self->{receive_size}, 0)) {
					$self->{on_recv}($buffer, $self, $addr);
				}
				$self->_error(1, "Couldn't recv: $!") if $! != EAGAIN and $! != EWOULDBLOCK;
				return;
			};

			last;
		}
	});
	return;
}

sub _error {
	my ($self, $fatal, $message) = @_;

	if ($self->_has_error_handler) {
		$self->on_error->($self, $fatal, $message);
		$self->destroy if $fatal;
	} else {
		$self->destroy;
		croak "AnyEvent::Handle uncaught error: $message";
	}
	return;
}

sub push_send {
	my ($self, $message, $to, $cv) = @_;
	$cv ||= defined wantarray ? AnyEvent::CondVar->new : undef;
	if (!$self->{writer}) {
		my $ret = $self->_send($message, $to, $cv);
		$self->_push_writer($message, $to, $cv) if not defined $ret and ($! == EAGAIN or $! == EWOULDBLOCK);
		$self->_drained if $ret;
	}
	else {
		$self->_push_writer($message, $to, $cv);
	}
	return $cv;
}

sub _send {
	my ($self, $message, $to, $cv) = @_;
	my $ret = defined $to ? send $self->{fh}, $message, 0, $to : send $self->{fh}, $message, 0;
	$self->on_error->($self->{fh}, 1, "$!") if not defined $ret and ($! != EAGAIN and $! != EWOULDBLOCK);
	$cv->($ret) if defined $cv and defined $ret;
	return $ret;
}

sub _push_writer {
	my ($self, $message, $to, $condvar) = @_;
	push @{$self->{buffers}}, [ $message, $to, $condvar ];
	$self->{writer} ||= AE::io $self->{fh}, 1, sub {
		if (@{ $self->{buffers} }) {
			while (my ($msg, $to, $cv) = shift @{$self->{buffers}}) {
				my $ret = $self->_send(@{$msg}, $to, $cv);
				if (not defined $ret) {
					unshift @{$self->{buffers}}, $msg;
					$self->on_error->($self->{fh}, 1, "$!") if $! != EAGAIN and $! != EWOULDBLOCK;
					last;
				}
			}
		}
		else {
			delete $self->{writer};
			$self->_drained;
		}
	};
	return $condvar;
}

sub destroy {
	my $self = shift;
	%{$self} = ();
	return;
}

1;

# ABSTRACT: client/server UDP handles for AnyEvent

__END__

=head1 DESCRIPTION

This module is an abstraction around UDP sockets for use with AnyEvent.

=method new

Create a new UDP handle. As arguments it accepts any attribute, as well as these two:

=over 4

=item * connect

Set the address to which datagrams are sent by default, and the only address from which datagrams are received. It must be either a packed sockaddr struct or an arrayref containing a hostname and a portnumber.

=item * bind

The address to bind the socket to. It must be either a packed sockaddr struct or an arrayref containing a hostname and a portnumber.

=back

All are optional, though using either C<connect> or C<bind> (or both) is strongly recommended unless you give it a connected/bound C<fh>.

=attr on_recv

The callback for when a package arrives. It takes three arguments: the datagram, the handle and the address the datagram was received from.

=attr on_error

The callback for when an error occurs. It takes three arguments: the handle, a boolean indicating the error is fatal or not, and the error message.

=attr on_drain

This sets the callback that is called when the send buffer becomes empty. The callback takes the handle as its only argument.

=attr receive_size

The buffer size for the receiving in bytes. It defaults to 1500, which is slightly more than the MTA on ethernet.

=attr family

Sets the socket family. The default is C<0>, which means either IPv4 or IPv6. The values C<4> and C<6> mean IPv4 and IPv6 respectively.

=attr fh

The underlying filehandle.

=method bind_to($address)

Bind to the specified addres. Note that a bound socket may be rebound to another address. C<$address> must be in the same form as the bind argument to new.

=method connect_to($address)

Connect to the specified address. Note that a connected socket may be reconnected to another address. C<$address> must be in the same form as the connect argument to new.

=method push_send($message, $to = undef, $cv = AnyEvent::CondVar->new)

Try to send a message. If a socket is not connected a receptient address must also be given. If it is connected giving a receptient may not work as expected, depending on your platform. It returns C<$cv>, which will become true when C<$message> is sent.

=method destroy

Destroy the handle.

=head1 BACKWARDS COMPATIBILITY

This module is B<not> backwards compatible in any way with the previous module of the same name by Jan Henning Thorsen. That module was broken by AnyEvent itself and now considered defunct.

=for Pod::Coverage
BUILD
=end

=cut
