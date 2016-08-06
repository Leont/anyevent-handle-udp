package AnyEvent::Handle::UDP;
use strict;
use warnings FATAL => 'all';

use AnyEvent qw//;
use AnyEvent::Util qw/fh_nonblocking/;
use AnyEvent::Socket qw/parse_address/;

use Carp qw/croak/;
use Errno qw/EAGAIN EWOULDBLOCK EINTR ETIMEDOUT/;
use Scalar::Util qw/reftype looks_like_number weaken openhandle/;
use Socket qw/SOL_SOCKET SO_REUSEADDR SOCK_DGRAM INADDR_ANY AF_INET AF_INET6 sockaddr_family/;
use Symbol qw/gensym/;

BEGIN {
	*subname = eval { require Sub::Name } ? \&Sub::Name::subname : sub { $_[1] };
}
use namespace::clean;
my %non_fatal = map { ( $_ => 1 ) } EAGAIN, EWOULDBLOCK, EINTR;

sub new {
	my ($class, %args) = @_;
	my $self = bless {
		on_recv      => $args{on_recv} || croak('on_recv not given'),
		reuse_addr   => exists $args{reuse_addr} ? !!$args{reuse_addr} : 1,
		receive_size => $args{receive_size} || 1500,
		family       => $args{family}       || 0,
		autoflush    => $args{autoflush}    || 0,
		buffers      => [],
	}, $class;
	$self->{$_} = $args{$_} for grep { exists $args{$_} } qw/on_drain on_error on_timeout on_rtimeout on_wtimeout/;
	$self->{$_} = AE::now() for qw/activity ractivity wactivity/;

	$self->{fh} = bless gensym(), 'IO::Socket';
	$self->_bind_to($self->{fh}, $args{bind}) if exists $args{bind};
	$self->_connect_to($self->{fh}, $args{connect}) if exists $args{connect};

	$self->$_($args{$_}) for grep { exists $args{$_} } qw/timeout rtimeout wtimeout/;

	$self->_drained;
	return $self;
}

sub _insert {
	my ($name, $sub) = @_;
	no strict 'refs';
	*{$name} = subname $name, $sub;
}

for my $name (qw/on_recv on_error on_timeout on_rtimeout on_wtimeout autoflush receive_size/) {
	_insert($name, sub {
		my $self = shift;
		$self->{$name} = shift if @_;
		return $self->{$name};
	});
}

for my $name (qw/sockname peername/) {
	_insert($name, sub {
		my $self = shift;
		return $self->{fh}->$name;
	});
}

sub on_drain {
	my $self = shift;
	if (@_) {
		$self->{on_drain} = shift;
		$self->_drained if not @{ $self->{buffers} };
	}
	return $self->{on_drain};
}

sub _drained {
	my $self = shift;
	$self->{on_drain}->($self) if defined $self->{on_drain};
}

for my $dir ('', 'r', 'w') {
	my $timeout = "${dir}timeout";
	my $activity = "${dir}activity";
	my $on_timeout = "on_$timeout";
	my $timer = "${dir}timer";
	my $clear_timeout = "clear_$timeout";
	my $timeout_reset = "${timeout}_reset";

	my $callback;
	$callback = sub {
		my $self = shift;
		if (not exists $self->{$timeout} or not $self->{fh}) {
			delete $self->{$timer};
			return;
		}
		my $now = AE::now;
		my $after = $self->{$activity} + $self->{$timeout} - $now;
		if ($after <= 0) {
			$self->{$activity} = $now;
			my $time = $self->{$on_timeout};
			my $error = do { local $! = Errno::ETIMEDOUT; "$!" };
			$time ? $time->($self) : $self->_error->(0, $error);
			return if not exists $self->{$timeout};
		}
		weaken $self;
		return if not $self;
		$self->{$timer} = AE::timer($after, 0, sub {
			delete $self->{$timer};
			$callback->($self);
		});
	};

	_insert($timeout, sub {
		my $self = shift;
		if (@_) {
			my $value = shift;
			$self->{$timeout} = $value;
			if ($value == 0) {
				delete $self->{$timer};
				delete $self->{$timeout};
				return;
			}
			else {
				$callback->($self);
			}
		}
		return $self->{$timeout};
	});

	_insert($clear_timeout, sub {
		my $self = shift;
		delete $self->{$timeout};
		return;
	});

	_insert($timeout_reset, sub {
		my $self = shift;
		$self->{$activity} = AE::now;
	});
}

sub bind_to {
	my ($self, $addr) = @_;
	return $self->_bind_to($self->{fh}, $addr);
}

my $add_reader = sub {
	my $self = shift;
	$self->{reader} = AE::io($self->{fh}, 0, sub {
		while (defined (my $addr = recv $self->{fh}, my ($buffer), $self->{receive_size}, 0)) {
			$self->timeout_reset;
			$self->rtimeout_reset;
			$self->{on_recv}->($buffer, $self, $addr);
		}
		$self->_error(1, "Couldn't recv: $!") if not $non_fatal{$! + 0};
		return;
	});
};

sub _bind_to {
	my ($self, $fh, $addr) = @_;
	my $bind_to = sub {
		my ($domain, $type, $proto, $sockaddr) = @_;
		if (!openhandle($fh)) {
			socket $fh, $domain, $type, $proto or redo;
			fh_nonblocking $fh, 1;
			setsockopt $fh, SOL_SOCKET, SO_REUSEADDR, 1 or $self->_error(1, "Couldn't set so_reuseaddr: $!") if $self->{reuse_addr};
			$add_reader->($self);
		}
		bind $fh, $sockaddr or $self->_error(1, "Could not bind: $!");
	};
	if (ref $addr) {
		my ($host, $port) = @{$addr};
		_on_addr($self, $fh, $host, $port, $bind_to);
	}
	else {
		$bind_to->(sockaddr_family($addr), SOCK_DGRAM, 0, $addr);
	}
	return;
}

sub connect_to {
	my ($self, $addr) = @_;
	return $self->_connect_to($self->{fh}, $addr);
}

sub _connect_to {
	my ($self, $fh, $addr) = @_;
	my $connect_to = sub {
		my ($domain, $type, $proto, $sockaddr) = @_;
		if (!openhandle($fh)) {
			socket $fh, $domain, $type, $proto or redo;
			fh_nonblocking $fh, 1;
			$add_reader->($self);
		}
		connect $fh, $sockaddr or $self->_error(1, "Could not connect: $!");
	};
	if (ref $addr) {
		my ($host, $port) = @{$addr};
		_on_addr($self, $fh, $host, $port, $connect_to);
	}
	else {
		$connect_to->(sockaddr_family($addr), SOCK_DGRAM, 0, $addr);
	}
	return;
}

my $get_family = sub {
	my ($self, $fh) = @_;
	return $self->{family} if !openhandle($fh) || !getsockname $fh;
	my $family = sockaddr_family(getsockname $fh);
	return +($family == AF_INET) ? 4 : ($family == AF_INET6) ? 6 : $self->{family};
};

sub _on_addr {
	my ($self, $fh, $host, $port, $on_success) = @_;

	AnyEvent::Socket::resolve_sockaddr($host, $port, 'udp', $get_family->($self, $fh), SOCK_DGRAM, sub {
		my @targets = @_;
		while (1) {
			my $target = shift @targets or $self->_error(1, "Could not resolve $host:$port");
			$on_success->(@{$target});
			last;
		}
	});
	return;
}

sub _error {
	my ($self, $fatal, $message) = @_;

	if (exists $self->{error_handler}) {
		$self->{on_error}->($self, $fatal, $message);
		$self->destroy if $fatal;
	} else {
		$self->destroy;
		croak "AnyEvent::Handle::UDP uncaught error: $message";
	}
	return;
}

sub push_send {
	my ($self, $message, $to, $cv) = @_;
	$to = AnyEvent::Socket::pack_sockaddr($to->[1], defined $to->[0] ? parse_address($to->[0]) : INADDR_ANY) if ref $to;
	$cv ||= AnyEvent::CondVar->new if defined wantarray;
	if ($self->{autoflush} and ! @{ $self->{buffers} }) {
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
	$self->_error(1, "Could not send: $!") if not defined $ret and !$non_fatal{$! + 0};
	if (defined $cv and defined $ret) {
		$self->timeout_reset;
		$self->wtimeout_reset;
		$cv->($ret);
	}
	return $ret;
}

sub _push_writer {
	my ($self, $message, $to, $condvar) = @_;
	push @{ $self->{buffers} }, [ $message, $to, $condvar ];
	$self->{writer} ||= AE::io $self->{fh}, 1, sub {
		if (@{ $self->{buffers} }) {
			while (my $entry = shift @{ $self->{buffers} }) {
				my ($msg, $to, $cv) = @{$entry};
				my $ret = $self->_send($msg, $to, $cv);
				if (not defined $ret) {
					unshift @{ $self->{buffers} }, $entry if $self->{buffers};
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

=head1 SYNOPSIS

 my $echo_server = AnyEvent::Handle::UDP->new(
     bind => ['0.0.0.0', 4000],
     on_recv => sub {
         my ($data, $ae_handle, $client_addr) = @_;
         $ae_handle->push_send($data, $client_addr);
     },
 );
 
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

All except C<on_recv> are optional, though using either C<connect> or C<bind> (or both) is strongly recommended unless you give it a connected/bound C<fh>.

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

The underlying filehandle. Note that this doesn't cooperate with the C<connect> and C<bind> parameters.

=attr reuse_addr

If true will enable quick reuse of the bound address

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

=method sockname

Get the local address, per C<getsockname>.

=method peername

Get the peer's address, per C<getpeername>.

=method destroy

Destroy the handle.

=head1 BACKWARDS COMPATIBILITY

This module is B<not> backwards compatible in any way with the defunct previous module of the same name by Jan Henning Thorsen. 

=cut

=for Pod::Coverage
clear_timeout
clear_rtimeout
clear_wtimeout
=end
