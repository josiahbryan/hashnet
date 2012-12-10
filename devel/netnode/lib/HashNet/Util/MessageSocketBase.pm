
{package HashNet::Util::MessageSocketBase;

	use common::sense;
	use Data::Dumper;
	use POSIX qw( WNOHANG );
	use JSON qw/to_json from_json/;
	
	use HashNet::Util::CleanRef;
	
	use Time::HiRes qw/sleep alarm time/; # needed for exec_timeout
	
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
				print "Child $$ running\n";
				$self->process_loop();
				print "Child $$ complete, exiting\n";
				exit 0;
			}
			
			# Parent continues here.
			while ((my $k = waitpid(-1, WNOHANG)) > 0)
			{
				# $k is kid pid, or -1 if no such, or 0 if some running none dead
				my $stat = $?;
				print "Reaped $k stat $stat\n";
			}
		}
	}
	
	sub exec_timeout($$)
	{
		my $timeout = shift;
		my $sub = shift;
		#debug "\t exec_timeout: \$timeout=$timeout, sub=$sub\n";
		
		my $timed_out = 0;
		local $@;
		eval
		{
			#debug "\t exec_timeout: in eval, timeout:$timeout\n";
			local $SIG{ALRM} = sub
			{
				#debug "\t exec_timeout: in SIG{ALRM}, dieing 'alarm'...\n";
				$timed_out = 1;
				die "alarm\n"
			};       # NB \n required
			my $previous_alarm = alarm $timeout;

			#debug "\t exec_timeout: alarm set, calling sub\n";
			$sub->(@_); # Pass any additional args given to exec_timout() to the $sub ref
			#debug "\t exec_timeout: sub done, clearing alarm\n";

			alarm $previous_alarm;
		};
		#debug "\t exec_timeout: outside eval, \$\@='$@', \$timed_out='$timed_out'\n";
		die if $@ && $@ ne "alarm\n";       # propagate errors

		$timed_out = $@ ? 1:0 if !$timed_out;
		#debug "\t \$timed_out flag='$timed_out'\n";
		return $timed_out;
	}
	
	sub process_loop
	{
		my $self = shift;
		
		$self->connect_handler();
		
		#my $read_socket  = $socket eq '-' ? *STDIN  : $socket;
		#my $write_socket = $socket eq '-' ? *STDOUT : $socket;
		
		my $zero_counter = 0;
		my $sock = $self->{sock};
		
		#my $counter = 0;
		
		undef $@;
		eval
		{
			PROCESS_LOOP:
			while(1)
			{
				my $first_line;
				
				#print STDERR __PACKAGE__.": process_loop(): Loop# $counter\n";
				#$counter ++;
				
				# TODO: Send any stuff from outside the process
				# TODO: Determine how to get data in from outside the process - database? DBM::Deep
				
				my @messages = $self->pending_messages();
				$self->send_message($_) foreach @messages;
				
				#print STDERR "\t mark1\n";
				my $timed_out = exec_timeout 0.1, sub { $first_line = $sock->getline() };
				#print STDERR "\t mark2\n";
				
				next PROCESS_LOOP if $timed_out;
				
				if($first_line =~ /^\D/)
				{
					# Assume client is lazy, speak only JSON with newlines encoded, don't prepend outgoing messages with byte counts
					$self->{dialect} = 2;
					# NOTE {dialect} not used anywhere yet...
					
					if($first_line =~ /^(GET|POST)\s+\//)
					{
						#print STDERR "Client speaking HTTP, not processing\n";
						last PROCESS_LOOP;
					}
					
					$first_line =~ s/[\r\n]$//g;
					$self->process_message($first_line);
					
					next PROCESS_LOOP;
				}
				
				#print STDERR "Debug: First line: '$first_line'\n";
				
				my $bytes_expected = int($first_line);
				
				if($bytes_expected <= 0)
				{
					if($zero_counter ++)
					{
						#print STDERR "Client sending 0's for data, disconnecting\n";
						last PROCESS_LOOP;
					}
					
					next PROCESS_LOOP;
				}
				
				$zero_counter = 0;
				
				my $bytes_rxd = 0;
				my @buffer;
				
				#print STDERR "Expecting $bytes_expected bytes...\n";
				
				# Add a timeout around the read loop because we want to prevent the the read loop getting
				# hung up in the event of a corrupted value received for $bytes_expected
				eval
				{
					# We're doing our own alarm() setup instead of using exec_timeout() because
					# we reset the alarm each time they send a byte of data instead of expecting it all in, for example, 30 sec
					
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
						
						#print STDERR "Read($res): $data\n";
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
					last PROCESS_LOOP;
				}
			
				
				my $data = join '', @buffer;
				my $len = length $data;
				#print STDERR "Final answer: len:$len/$bytes_expected, data: '$data'\n";
				#print STDERR "Data: '$data'\n";
				
				$self->process_message($data);
			}
		
			
	# 		PROCESS_LOOP: while (<$read_socket>)
	# 		{
	# 			s/[\r\n]+$//;
	# 			print $write_socket "You said '$_'\015\012"; # basic echo
	# 			last PROCESS_LOOP if /quit/i;
	# 		}
			
		};
		if($@)
		{
			print STDERR "\nError in process_loop(): $@";
		}
		
		$self->disconnect_handler();
	}
	
	sub process_message
	{
		my $self = shift;
		my $msg  = shift;
		
		if($msg =~ /^[\w-]+:\s+/ || $msg =~ /^(GET|POST)\s+\//)
		{
			# looks like a http request or header..
			#print STDERR "Ignore HTTP request/header: '$msg'\n";
			return;
		}
		
		if(!$msg)
		{
			# Ignore empty message
			return;
		}
		
		my $type = 'json'; # assume json
		my $boundary = undef;
			
		if($msg =~ /^Content-Type:\s*(.*?)$/)
		{
			$type = $1;
			$boundary = undef;
		
			if($type =~ /multipart\/mixed; boundary=(.*)/)
			{
				$boundary = $1;
			}
			#Content-Type: multipart/mixed;
			#boundary=gc0p4Jq0M2Yt08jU534c0p
			$msg =~ s/^Content-Type:.*?$//g;
			
			$type = 'json' if $type =~ /json/;
		}
		
		my $second_part = undef;
		if($boundary)
		{
			my $idx = index($msg, $boundary);
			$msg = substr($msg, $idx-1);
			$second_part = substr($msg, $idx+length($boundary));
		}
		
		#print STDERR "Got msg: $msg\n";
		
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
		my $msg  = to_json(HashNet::Util::CleanRef->clean_ref($hash))."\015\012";
		my $sock = $self->{sock};
		print $sock $msg;
	}
	
	# TODO: Override in subclasses to return a list of pending messages to send using send_message() in process_loop
	sub pending_messages
	{
		return ();
	}
	
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
