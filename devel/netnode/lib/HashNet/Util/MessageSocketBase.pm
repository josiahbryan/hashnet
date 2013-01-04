
{package HashNet::Util::MessageSocketBase;

	use common::sense;
	use Data::Dumper;
	use POSIX qw( WNOHANG );
	use JSON qw/to_json from_json/;
	use Time::HiRes qw/sleep time alarm/;
	
	use HashNet::Util::CleanRef;
	use HashNet::Util::Logging;
	use HashNet::Util::ExecTimeout;

	use UUID::Generator::PurePerl; # for use in boundary generation
	my $UUID_GEN = UUID::Generator::PurePerl->new();

	sub CRLF { "\015\012" }
	
	sub new
	{
		my $class = shift;
		my %opts = @_;
		
		$opts{auto_start} = 1 if !defined $opts{auto_start};
		
		my $self = bless \%opts, $class;
		
		$self->start if $self->{auto_start};
		
		
		return $self;
	}
	
	sub start
	{
		my $self = shift;
		if($self->{no_fork})
		{
			$self->process_loop();
		}
		else
		{
			# Fork processing thread
			my $kid = fork();
			die "Fork failed" unless defined($kid);
			if ($kid == 0)
			{

				# This sequence of functions to get the IP/port/hostname
				# taken from http://perldoc.perl.org/functions/getpeername.html
				use Socket;
				my $sock           = $self->{sock};
				my $hersockaddr    = getpeername($sock);
				my ($port, $iaddr) = sockaddr_in($hersockaddr);
				my $herhostname    = gethostbyaddr($iaddr, AF_INET);
				my $herstraddr     = inet_ntoa($iaddr);

				$0 = "$0 [Peer $herhostname]";
				trace "MessageSocketBase: Connected to $herstraddr:$port ($herhostname) in PID $$ as '$0'\n";

				#info "MessageSocketBase: Child $$ running\n";
				$self->process_loop();
				#info "MessageSocketBase: Child $$ complete, exiting\n";
				exit 0;
			}

			# Parent continues here.
			while ((my $k = waitpid(-1, WNOHANG)) > 0)
			{
				# $k is kid pid, or -1 if no such, or 0 if some running none dead
				my $stat = $?;
				debug "Reaped $k stat $stat\n";
			}

			$self->{child_pid} = $kid;
		}
	}

	sub stop
	{
		my $self = shift;
		if($self->{child_pid})
		{
			kill 15, $self->{child_pid};
		}
	}

	sub DEBUG_RX { 1 }

	use IO::Select;
	
	sub process_loop
	{
		my $self = shift;
		
		$self->connect_handler();
		
		#my $read_socket  = $socket eq '-' ? *STDIN  : $socket;
		#my $write_socket = $socket eq '-' ? *STDOUT : $socket;
		
		$self->{zero_counter} = 0;
		
		my $sock = $self->{sock};

		# IO::Socket has autoflush turned on by default
		$sock->autoflush(1);
		#$sock->blocking(0);

		my $sel = IO::Select->new();
		$sel->add($sock);
		
		#my $counter = 0;

		Restart_Process_Loop:

		undef $@;
		eval
		{
			PROCESS_LOOP:
			while(1)
			{
				my @messages = $self->pending_messages();
				my $msg_total = scalar @messages;
				my $msg_counter = 0;

				#trace "MessageSocketBase: Found $msg_total messages to send...\n" if $msg_total;
				my @sent;
				my $limit = 256;  # an arbitrary max number of messages to send on one loop
				my $max_msg = $msg_total > $limit ? $limit : $msg_total;
				@messages = @messages[0..$max_msg] if $msg_total != $max_msg;
				foreach my $msg (@messages)
				{
					#trace "MessageSocketBase: wait for can_write\n";

					# Set a very low timeout to can_write() because we use this to detect when the socket buffer is full
					# (eg waiting on the other side to process) - since we may hit can_write() several thousand times
					# a second if there are a lot of messages to write, we don't want to wait for it to return
					if($sel->can_write(0.001 / ($limit * 100)))
					{
						#trace "MessageSocketBase: Sending msg $msg_counter/$max_msg ($msg_total actual): '$msg->{data}'\n";
						$self->send_message($msg);

						push @sent, $msg;
						$msg_counter ++;
						#trace "MessageSocketBase: call to send_message done\n";
						#trace "MessageSocketBase: timedout sending msg $msg_counter, skipping the rest of the messages till we read some data\n";
					}
				}
				$self->messages_sent(\@sent);

				# If the buffer is full, add some 'yield' to this thread to not chew up CPU while we wait on the other side to process
				sleep 0.75 if $msg_total && $msg_total != $msg_counter;

				#trace "MessageSocketBase: Sent $msg_counter messages out of $msg_total\n" if $msg_total;

				# Subclasses can use this hook to block updates while doing bulk reads
				$self->bulk_read_start_hook();

				#trace "MessageSocketBase: Enter bulk read loop\n";

				my $done_reading = 0;
				while(!$done_reading)
				{
					my $ret = $self->read_message();

					# read_message() returns -1 if fatal
					#last PROCESS_LOOP if $ret < 0;
					if($ret < 0)
					{
						$self->bulk_read_end_hook();
						last PROCESS_LOOP;
					}

					# DON'T do while(can_read) because can_read COULD lie!
					# If can_read lied when used in while(), then you might
					# never read some data. This way, we ASSUME there
					# is data to read and read_message() can gracefully
					# timeout if there really isn't data there.
					$done_reading = $sel->can_read(0.01) ? 0 : 1;
				}

				#trace "MessageSocketBase: Exit bulk read loop\n";

				$self->bulk_read_end_hook();
			}
		
			
	# 		PROCESS_LOOP: while (<$read_socket>)
	# 		{
	# 			s/[\r\n]+$//;
	# 			print $write_socket "You said '$_'\015\012"; # basic echo
	# 			last PROCESS_LOOP if /quit/i;
	# 		}
			
		};
		my $die_please = 0;
		if(my $err = $@)
		{
			print STDERR "\nError in process_loop(): $err";
			$die_please = 1;

# 			# Attempt to recover from some common errors
# 			if($err =~ /Use of init.*DBM\/Deep\/Engine\/File/)
# 			{
# 				HashNet::MP::LocalDB->reset_cached_handles();
# 				goto Restart_Process_Loop;
# 			}
			
		}
		
		$self->disconnect_handler();
		die "Quitting process due to error above" if $die_please;
	}

	sub read_message
	{
		my $self = shift;
		my $sock = $self->{sock};

		my $first_line;
		#print STDERR "\t mark1\n";
		my $timed_out = exec_timeout 0.1, sub { $first_line = $sock->getline() };
		#print STDERR "\t mark2\n";

		return 0 if $timed_out;

		# line starts with anything but digits...
		if($first_line =~ /^\D/)
		{
			# Assume client is lazy, speak only JSON with newlines encoded, don't prepend outgoing messages with byte counts
			$self->{dialect} = 2;
			# NOTE {dialect} not used anywhere yet...

			if($first_line =~ /^(GET|POST)\s+\//)
			{
				#print STDERR "Client speaking HTTP, not processing\n";
				return -1;
			}

			# Trim newline and pass text to process_message()
			$first_line =~ s/[\r\n]$//g;

			#trace "MessageSocketBase: Non-integer first line, '$first_line'\n";

			$self->process_message($first_line);

			return 1;
		}

		#print STDERR "Debug: First line: '$first_line'\n";
		my $bytes_expected = int($first_line);

		#trace "MessageSocketBase: First Line: '$first_line', int(): $bytes_expected\n" if DEBUG_RX;

		if($bytes_expected <= 0)
		{
			if($self->{zero_counter} ++)
			{
				#trace "MessageSocketBase: Client sending 0's for data, disconnecting\n";
				return -1;
			}

			return 0;
		}

		$self->{zero_counter} = 0;

		my $bytes_rxd = 0;
		my @buffer;

		#print STDERR "Expecting $bytes_expected bytes...\n";

		# Add a timeout around the read loop because we want to prevent the the read loop getting
		# hung up in the event of a corrupted value received for $bytes_expected
		eval
		{
			# We're doing our own alarm() setup instead of using exec_timeout() because
			# we reset the alarm each time they send a chunk of data instead of expecting it all in, for example, 30 sec

			local $SIG{'ALRM'} = sub { die "Timed Out!\n" };
			my $timeout = 30; # give the user 30 seconds to type some lines

			my $previous_alarm = alarm($timeout);

			BUFRD:
			while (1)
			{
				$! = 0;
				my $data;
				my $res = $sock->read($data, $bytes_expected - $bytes_rxd);
				# res: #chars, or 0 for EOF, or undef for error
				die "read failed on $!" unless defined($res);
				last BUFRD if $res == 0; # EOF

				#print STDERR "Read($res, $bytes_rxd): $data\n";
				push @buffer, $data;
				$bytes_rxd += $res;

				last BUFRD if $bytes_rxd >= $bytes_expected;

				alarm($timeout);
			}

			alarm($previous_alarm);

		};

		if ($@ =~ /timed out/i)
		{
			print STDERR "Timed Out.\r\n";
			return -1;
		}


		my $data = join '', @buffer;
		#my $len = length $data;
		#print STDERR "Final answer: len:$len/$bytes_expected, data: '$data'\n";
		#print STDERR "Data: '$data'\n";

		#trace "MessageSocketBase: Data: '$data'\n" if DEBUG_RX;

		$self->process_message($data);

		return 1;
	}
	
	sub process_message
	{
		my $self = shift;
		my $msg  = shift;
		
		#if($msg =~ /^[\w-]+:\s+/ || $msg =~ /^(GET|POST)\s+\//)
		if($msg =~ /^(GET|POST)\s+\//)
		{
			# looks like a http request or header..
			trace "MessageSocketBase: process_message(): Ignore HTTP request/header: '$msg'\n";
			return;
		}
		
		if(!$msg)
		{
			# Ignore empty message
			return;
		}
		
		my $type = 'json'; # assume json
		my $boundary = undef;

		# Content-Type, up to and including the boundary string is expected to be on one line
		if($msg =~ /^Content-Type:\s*(.*)[\r\n]*/)
		{
			$type = $1;
			$boundary = undef;

			#trace "MessageSocketBase: process_message(): Content-Type: '$type'\n";

			if($type =~ /multipart\/mixed; boundary=(.*)$/)
			{
				$boundary = $1;
				$boundary =~ s/[\r\n]//g;
				#trace "MessageSocketBase: process_message(): boundary: '$boundary'\n";
			}

			#Content-Type: multipart/mixed;
			#boundary=gc0p4Jq0M2Yt08jU534c0p

			# Remove the first line
			$msg =~ s/^Content-Type:.*[\n\r]*//g;

			# Cheat with application/json or text/json
			$type = 'json' if $type =~ /json/ || $type =~ /^multipart\/mixed/;

			#die "good: $type";
			#trace "MessageSocketBase: process_message(): Message after type removal: '$msg'\n";
		}

		my $second_part = undef;
		if($boundary)
		{
			# TODO: Adapt to handle "--$boundary", not just "$boundary"
			my $idx = index($msg, $boundary);
			my $len = length($boundary);
			my $first_part = substr($msg, 0, $idx);
			$second_part = substr($msg, $idx + $len);

			#trace "MessageSocketBase: process_message(): idx: $idx, len: $len\n"; #, msg: '$msg', boundary: '$boundary'\n";

			$msg = $first_part;
		}

		#print STDERR "Got msg: $msg\n";

		#trace "MessageSocketBase: process_message():\n\tmsg: '$msg'\n\tatt: '$second_part'\n" if $second_part;
		
		my $sock = $self->{sock};
		#print $sock "Thanks, I got: '$msg'\n";
		
		my $hash = $msg;
		if($type eq 'json')
		{
			undef $@;
			eval { $hash = from_json($msg) };
			
			if($@)
			{
				my $error = $@;
				$error =~ s/ at \/.*?JSON.pm.*?[\n\r]+//g;
				
				$self->bad_message_handler($msg, $error);
				return;
			}
		}
		#print STDERR "Message: ".Dumper($hash);
		
		$self->dispatch_message($hash, $second_part);
	}
	
	# NOTE: May override in subclass, not required
	sub bad_message_handler
	{
		my $self    = shift;
		my $bad_msg = shift;
		my $error   = shift;
		
		print STDERR "bad_message_handler: '$error' (bad_msg: $bad_msg)\n";
		$self->send_message({ type => "error", error => $error, bad_msg => $bad_msg });
	}
	
	# NOTE: Override in subclass
	sub dispatch_message
	{
		my $self = shift;
		my $hash = shift;
		my $second_part = shift;
		
		print STDERR "dispatch_message: hash: ".Dumper($hash)."\n";
		
		#$self->send_message({ received => $hash }); 
	}
	
	# NOTE: Use in subclass
	sub send_message
	{
		my $self = shift;
		my $hash = shift;
		my $att  = shift;
		my $json = "";
		my $clean_ref = undef;
		#trace "MessageSocketBase: send_message: $hash->{type}: '$hash->{data}'\n";
		undef $@;
		eval {
			$clean_ref = clean_ref($hash);
		};
		if($@)
		{
			use Carp;
			Carp::cluck "send_message: Error cleaning ref: $@, orig ref: ".Dumper($hash);
			return;
		}
		if(!$att && defined $clean_ref->{_att})
		{
			$att = $clean_ref->{_att};
			delete $clean_ref->{_att};
		}
		#trace "MessageSocketBase: send_message: encoding json\n";
		undef $@;
		eval {
			$json = to_json($clean_ref)
		};
		if($@)
		{
			use Carp;
			Carp::cluck "send_message: Error encoding json: $@";
			return;
		}

		if(defined $att)
		{
			#trace "MessageSocketBase: send_message: has att, generating output\n";
			my $boundary = $UUID_GEN->generate_v1->as_string();

			my @tmp;
			# First line will be XCRLF where X is length of final buffer
			# Second line is Content-type
			# Third line is JSON
			# Fourth line STARTS with $boundary, then immediately followed by $att
			push @tmp,"Content-Type: multipart\/mixed; boundary=".$boundary.CRLF;
			push @tmp, $json.CRLF;
			push @tmp, $boundary;
			
			my $buffer    = join '', @tmp;
			my $total_len = length($buffer) + length($att);

			# We print the buffer and att directly to the $sock instead of building up
			# a temporary $msg variable, then printing $msg to the sock because that
			# at least one memory copy (copy $att into the $msg) - this way, we
			# dont ever move $att into a buffer, it just goes from the $hash (or
			# @_ arg list) to the socket
			my $sock = $self->{sock};

			# This is the real code
			#trace "MessageSocketBase: send_message: Sending '$buffer' [with att]\n";
			print $sock $total_len.CRLF;
			print $sock $buffer;
			print $sock $att;

			my $oldfh = select $sock;
			$| ++;
			select $oldfh;
			

			# For debugging
			#my $msg = $total_len.CRLF.$buffer.$att;
			#trace "MessageSocketBase: \$msg: ".Dumper(\$msg);
			#print $sock $msg;
			#print $sock $att;
			
			# TODO: Write test for this functionality
		}
		else
		{
			my $msg  = $json.CRLF;
			my $sock = $self->{sock};
			#trace "MessageSocketBase: send_message: Sending '$msg' [no att]\n";
			print $sock $msg;
		}

		#trace "MessageSocketBase: send_message: print() done\n";
		
  
	}
	
	# TODO: Override in subclasses to return a list of pending messages to send using send_message() in process_loop
	sub pending_messages
	{
		return ();
	}

	# TODO: Override in subclasses
	sub messages_sent
	{
	
	}

	sub bulk_read_start_hook {}
	sub bulk_read_end_hook {}
	
	# NOTE: Can override in subclasses
	sub connect_handler
	{
		my $self = shift;
		# Nothing done here
	}
	
	# NOTE: Can override in subclasses
	sub disconnect_handler
	{
		my $self = shift;
		# Nothing done here
	}
};
1;
