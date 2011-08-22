package AnyEvent::Handle::UDP;
use strict;
use warnings FATAL => 'all';

use AnyEvent qw//;
use AnyEvent::Util qw/fh_nonblocking/;
use AnyEvent::Socket qw//;

use Carp qw/croak/;
use Const::Fast qw/const/;
use Class::XSAccessor accessors => [qw/on_recv on_error receive_size/], getters => [qw/fh/];
use Errno qw/EAGAIN EWOULDBLOCK/;
use Socket qw/SOL_SOCKET SO_REUSEADDR/;

const my $default_recv_size => 1500;

sub new {
	my ($class, %options) = @_;

	croak 'on_recv option is mandatory' if not defined $options{on_recv};
	$options{receive_size} ||= $default_recv_size;

	my $self = bless { map { ( $_ => $options{$_} ) } qw/on_recv receive_size on_error/ }, $class;

	$self->bind_to($options{bind}) if $options{bind};
	$self->connect_to($options{connect}) if $options{connect};
	return $self;
}

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

	AnyEvent::Socket::resolve_sockaddr($host, $port, 'udp', 0, undef, sub {
		my @targets = @_;
		while (1) {
			my $target = shift @targets or $self->_error(1, "No such host '$host' or port '$port'");
	 
			my ($domain, $type, $proto, $sockaddr) = @{$target};
			my $full = join ':', $domain, $type, $proto;
			if ($self->{fh}) {
				return redo if $self->{full} ne $full;
			}
			else {
				socket $self->{fh}, $domain, $type, $proto or redo;
				fh_nonblocking $self->{fh}, 1;
				$self->{full} = $full;
			}

			$on_success->($sockaddr);

			$self->{reader} = AE::io $self->{fh}, 0, sub {
				while (defined (my $addr = recv $self->{fh}, my ($buffer), $self->{receive_size}, 0)) {
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

	if ($self->{on_error}) {
		$self->{on_error}($self, $fatal, $message);
		$self->destroy if $fatal;
	} else {
		$self->destroy;
		croak "AnyEvent::Handle uncaught error: $message";
	}
	return;
}

sub push_send {
	my ($self, $message, $to) = @_;
	my $ret = $self->_send();
	$self->_push_writer($message, $to) if not defined $ret and ($! == EAGAIN or $! == EWOULDBLOCK);
	return;
}

sub _send {
	my ($self, $message, $to) = @_;
	my $ret = defined $to ? send $self->{fh}, $message, 0, $to : send $self->{fh}, $message, 0;
	$self->on_error->($self->{fh}, 1, "$!") if not defined $ret and ($! != EAGAIN and $! != EWOULDBLOCK);
	return $ret;
}

sub _push_writer {
	my ($self, $message, $to) = @_;
	push @{$self->{buffers}}, [ $message, $to ];
	$self->{writer} ||= AE::io $self->{fh}, 1, sub {
		if (@{$self->{buffers}}) {
			while (my $msg = shift @{$self->{buffers}}) {
				if (not defined $self->_send(@{$msg})) {
					unshift @{$self->{buffers}}, $msg;
					last;
				}
			}
		}
		else {
			delete $self->{writer};
		}
	};
	return;
}

sub destroy {
	my $self = shift;
	$self->DESTROY;
	%{$self} = ();
	return;
}

sub DESTROY {
	my $self = shift;
	# XXX
	return;
}

1;

__END__

# ABSTRACT: client/server UDP handles for AnyEvent

=head1 DESCRIPTION

This module is an abstraction around UDP sockets for use with AnyEvent.

=method new

Create a new UDP handle. Its arguments are all optional, though using either connect or bind (or both) is strongly recommended.

=over 4

=item * connect

Set the address to which datagrams are sent by default, and the only address from which datagrams are received. It must be either a packed sockaddr struct or an arrayref containing a hostname and a portnumber.

=item * bind

The address to bind the socket to. It must be either a packed sockaddr struct or an arrayref containing a hostname and a portnumber.

=item * on_recv

The callback for when a package arrives. It takes three arguments: the datagram, the handle and the address the datagram was received from.

=item * on_error

The callback for when an error occurs. It takes three arguments: the handle, a boolean indicating the error is fatal or not, and the error message.

=item * receive_size

The buffer size for the receiving in bytes. It defaults to 1500, which is slightly more than the MTA on ethernet.

=back

=method bind_to($address)

Bind to the specified addres. Note that a bound socket may be rebound to another address. C<$address> must be in the same form as the bind argument to new.

=method connect_to($address)

Connect to the specified address. Note that a connected socket may be reconnected to another address. C<$address> must be in the same form as the connect argument to new.

=method push_send($message, $to?)

Try to send a message. If a socket is not connected a receptient address must also be given. It is connected giving a receptient may not work as expected, depending on your platform.

=head1 BACKWARDS COMPATIBILITY

This module is B<not> backwards compatible in any way with the previous module of the same name by Jan Henning Thorsen. That module was broken by AnyEvent itself and now considered defunct.
