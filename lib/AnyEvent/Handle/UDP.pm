package AnyEvent::Handle::UDP;
use strict;
use warnings FATAL => 'all';

use Moo;

use AnyEvent qw//;
use AnyEvent::Util qw/fh_nonblocking/;
use AnyEvent::Socket qw/parse_address/;

use Carp qw/croak/;
use Errno qw/EAGAIN EWOULDBLOCK EINTR ETIMEDOUT/;
use Scalar::Util qw/reftype looks_like_number weaken/;
use Socket qw/SOL_SOCKET SO_REUSEADDR SOCK_DGRAM INADDR_ANY/;
use Symbol qw/gensym/;

BEGIN {
	*subname = eval { require Sub::Name } ? \&Sub::Name::subname : sub { $_[1] };
}
use namespace::clean;

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
	$self->{buffers} = [];
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
	default => sub { 1500 },
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

has autoflush => (
	is => 'rw',
	default => sub { 0 },
);

for my $dir ('', 'r', 'w') {
	my $timeout = "${dir}timeout";
	my $clear_timeout = "clear_$timeout";
	my $has_timeout = "has_$timeout";
	my $activity = "_${dir}activity";
	my $on_timeout = "on_$timeout";
	my $timer = "_${dir}timer";
	my $clear_timer = "_clear$timer";
	my $timeout_reset = "${timeout}_reset";

	has $timer => (
		is => 'rw',
		clearer => $clear_timer,
	);

	my $callback;
	$callback = sub {
		my $self = shift;
		if (not $self->$has_timeout or not $self->fh) {
			$self->$clear_timer;
			return;
		}
		my $now = AE::now;
		my $after = $self->$activity + $self->$timeout - $now;
		if ($after <= 0) {
			$self->$activity($now);
			my $time = $self->$on_timeout;
			$time ? $time->($self) : $self->_error->(Errno::ETIMEDOUT, 0);
			return if not $self->$has_timeout;
		}
		weaken $self;
		return if not $self;
		$self->$timer(AE::timer($after, 0, sub {
			$self->$clear_timer;
			$callback->($self);
		}));
	};

	has $timeout => (
		is => 'rw',
		isa => sub {
			 return $_[0] >= 0;
		},
		predicate => $has_timeout,
		clearer => $clear_timeout,
		trigger => sub {
			my ($self, $value) = @_;
			if ($value == 0) {
				$self->$clear_timer;
				$self->$clear_timeout;
				return;
			}
			else {
				$callback->($self);
			}
		},
	);
	has $activity => (
		is => 'rw',
		default => sub { AE::now },
	);

	has $on_timeout => (
		is => 'rw',
		isa => sub { ref($_[0]) eq 'CODE' },
	);
	no strict 'refs';
	*{$timeout_reset} = subname $timeout_reset, sub {
		$activity = AE::now;
	};
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

	AnyEvent::Socket::resolve_sockaddr($host, $port, 'udp', $self->family, SOCK_DGRAM, sub {
		my @targets = @_;
		while (1) {
			my $target = shift @targets or $self->_error(1, "No such host '$host' or port '$port'");
	 
			my ($domain, $type, $proto, $sockaddr) = @{$target};
			my $full = join ':', $domain, $type, $proto;
			if ($self->_has_full) {
				redo if $self->_full ne $full;
			}
			else {
				socket $self->fh, $domain, $type, $proto or redo;
				fh_nonblocking $self->fh, 1;
				$self->_full($full);
			}

			$on_success->($sockaddr);

			$self->{reader} = AE::io $self->fh, 0, sub {
				while (defined (my $addr = recv $self->fh, my ($buffer), $self->{receive_size}, 0)) {
					$self->timeout_reset;
					$self->rtimeout_reset;
					$self->on_recv->($buffer, $self, $addr);
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

my %non_fatal = map { ( $_ => 1 ) } EAGAIN, EWOULDBLOCK, EINTR;

sub push_send {
	my ($self, $message, $to, $cv) = @_;
	$to = AnyEvent::Socket::pack_sockaddr($to->[1], defined $to->[0] ? parse_address($to->[0]) : INADDR_ANY) if ref $to;
	$cv ||= defined wantarray ? AnyEvent::CondVar->new : undef;
	if ($self->autoflush and ! @{ $self->{buffers} }) {
		my $ret = $self->_send($message, $to, $cv);
		$self->_push_writer($message, $to, $cv) if not defined $ret and $non_fatal{$! + 0};
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
	$self->_error(1, "$!") if not defined $ret and !$non_fatal{$! + 0};
	if (defined $cv and defined $ret) {
		$self->timeout_reset;
		$self->wtimeout_reset;
		$cv->($ret);
	}
	return $ret;
}

sub _push_writer {
	my ($self, $message, $to, $condvar) = @_;
	push @{$self->{buffers}}, [ $message, $to, $condvar ];
	$self->{writer} ||= AE::io $self->{fh}, 1, sub {
		if (@{ $self->{buffers} }) {
			while (my $entry = shift @{$self->{buffers}}) {
				my ($msg, $to, $cv) = @{$entry};
				my $ret = $self->_send($msg, $to, $cv);
				if (not defined $ret) {
					unshift @{$self->{buffers}}, $entry;
					$self->_error->(1, "$!") if !$non_fatal{$! + 0};
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

=attr autoflush

Always attempt to send data to the operating system immediately, without waiting for the loop to indicate the filehandle is write-ready.

=attr receive_size

The buffer size for the receiving in bytes. It defaults to 1500, which is slightly more than the MTA on ethernet.

=attr family

Sets the socket family. The default is C<0>, which means either IPv4 or IPv6. The values C<4> and C<6> mean IPv4 and IPv6 respectively.

=attr fh

The underlying filehandle.

=attr timeout

=attr rtimeout

=attr wtimeout

If non-zero, then these enables an "inactivity" timeout: whenever this many seconds pass without a successful read or write on the underlying file handle (or a call to C<timeout_reset>), the on_timeout callback will be invoked (and if that one is missing, a non-fatal ETIMEDOUT error will be raised).

There are three variants of the timeouts that work independently of each other, for both read and write (triggered when nothing was read OR written), just read (triggered when nothing was read), and just write: timeout, rtimeout and wtimeout, with corresponding callbacks on_timeout, on_rtimeout and on_wtimeout, and reset functions timeout_reset, rtimeout_reset, and wtimeout_reset.

Note that timeout processing is active even when you do not have any outstanding read or write requests: If you plan to keep the connection idle then you should disable the timeout temporarily or ignore the timeout in the corresponding on_timeout callback, in which case AnyEvent::Handle will simply restart the timeout.

Calling C<clear_timeout> (or setting it to zero, which does the same) disables the corresponding timeout.

=attr on_timeout

=attr on_rtimeout

=attr on_wtimeout

The callback that's called whenever the inactivity timeout passes. If you return from this callback, then the timeout will be reset as if some activity had happened, so this condition is not fatal in any way.

=method bind_to($address)

Bind to the specified addres. Note that a bound socket may be rebound to another address. C<$address> must be in the same form as the bind argument to new.

=method connect_to($address)

Connect to the specified address. Note that a connected socket may be reconnected to another address. C<$address> must be in the same form as the connect argument to new.

=method push_send($message, $to = undef, $cv = AnyEvent::CondVar->new)

Try to send a message. If a socket is not connected a receptient address must also be given. If it is connected giving a receptient may not work as expected, depending on your platform. It returns C<$cv>, which will become true when C<$message> is sent.

=method timeout_reset

=method rtimeout_reset

=method wtimeout_reset

Reset the activity timeout, as if data was received or sent.

=method destroy

Destroy the handle.

=head1 BACKWARDS COMPATIBILITY

This module is B<not> backwards compatible in any way with the defunct previous module of the same name by Jan Henning Thorsen. 

=for Pod::Coverage
BUILD
=end

=cut
