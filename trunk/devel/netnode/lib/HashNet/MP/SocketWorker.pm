use common::sense;
{package HashNet::MP::SocketWorker;

	use base qw/HashNet::Util::MessageSocketBase/;
	use JSON qw/to_json from_json/;
	use Data::Dumper;
	
	use Time::HiRes qw/time sleep/;

	use Carp qw/carp croak/;
	
	use HashNet::MP::PeerList;
	use HashNet::MP::LocalDB;
	use HashNet::MP::MessageQueues;
	
	use HashNet::Util::Logging;
	use HashNet::Util::CleanRef;
	
	use UUID::Generator::PurePerl; # for use in gen_node_info
	
	sub MSG_NODE_INFO	{ 'MSG_NODE_INFO' }
	sub MSG_INTERNAL_ERROR	{ 'MSG_INTERNAL_ERROR' }
	sub MSG_ACK		{ 'MSG_ACK' }
	sub MSG_USER		{ 'MSG_USER' }
	sub MSG_UNKNOWN		{ 'MSG_UNKNOWN' }

	# Can store our state_handle data in another db file if needed/wanted - just set this to the path of the file to use (autocreated)
	our $STATE_HANDLE_DB = undef;

	# Used to index the SocketWorkers for the running app
	our $STARTUP_PID = $$;

	# Simple utility method to auto-generate the node_info structure based on $0
	my $UUID_GEN = UUID::Generator::PurePerl->new(); 
	sub gen_node_info
	{
	
		my $dbh = HashNet::MP::LocalDB->handle;
		my $node_info = $dbh->{auto_clients}->{$0};
		if(!$node_info)
		{
			$node_info->{name} = $0;
			$node_info->{uuid} = $UUID_GEN->generate_v1->as_string();
			$node_info->{type} = 'client';
			$dbh->{auto_clients}->{$0} = $node_info;
		}
		
		#print STDERR "Debug: gen_node_info: node_info:".Dumper($node_info);

		# Return a 'clean' hash so user can use this ref across forks
		return clean_ref($node_info);
	}
	
	sub new
	{
		my $class = shift;
		
		# Allow single argument of $socket, assume no forking
		if(@_ == 1)
		{
			@_ = (
				sock    => $_[0],
				no_fork => 1
			);
		}

		my %opts = @_;
		
		# If we DON'T set auto_start to 0,
		# then ::new() may never return if
		# the caller set {no_fork} to a TRUE
		# value - ::new() would call start()
		# which would go right into a process_loop()
		# and we would never get the stack back from
		# new() until process_loop() ends.
		# By setting auto_start() to 0, we get the
		# chance to do other things before
		# 'risking' loosing the process by calling
		# start() at the end of our new()
		my $old_auto_start = $opts{auto_start}; 
		$opts{auto_start} = 0;
		
		# Auto-generate node_info as needed
		$opts{node_info} = $class->gen_node_info if !$opts{node_info};

		#die Dumper \%opts;
		
		my $self = $class->SUPER::new(%opts);

		# Create a UUID for this *object instance* to use to sync state across forks via LocalDB
		$self->{state_uuid} = $UUID_GEN->generate_v1->as_string();

		# Set startup flag to 0, will be set to 0.5 when connected and 1 when rx'd node_info from other side
		$self->state_update(1);
		$self->state_handle->{started} = 0;
		$self->state_update(0);

		# Allow the caller to call start() if desired
		$self->start unless defined $old_auto_start && !$old_auto_start;
		 
		return $self;
	}

	sub state_handle
	{
		my $self = shift;

		#trace "SocketWorker: state_handle: Access in $$\n";
		my $ref = HashNet::MP::LocalDB->handle($STATE_HANDLE_DB);

		$ref->load_changes;

		my $changes = 0;
		
		if(!$ref->{socketworker})
		{
			$ref->{socketworker} = {};
			$changes = 1;
		}
		
		my $id = $self->{state_uuid};
		my $sw = $ref->{socketworker};

		if(!$sw->{$id})
		{
			$sw->{$id} = {};
			$changes = 1;
		}

		$ref->save_data if $changes;

		#$self->{state_handle} = { ref => $ref, hdl => $sw->{$id} };
		#return $self->{state_handle}->{hdl};
		return $sw->{$id};
	}


	sub state_update
	{
		my $self = shift;
		my $flag = shift;
		my $ref = HashNet::MP::LocalDB->handle($STATE_HANDLE_DB);
		$ref->update_begin if  $flag;
		$ref->update_end   if !$flag;
	}

	sub DESTROY
	{
		my $self = shift;
		my $ref= HashNet::MP::LocalDB->handle($STATE_HANDLE_DB);

		# Remove the state data from the database
		$ref->update_begin;
		delete $ref->data->{socketworker}->{$self->{state_uuid}};
		$ref->update_end;
	}

	sub bad_message_handler
	{
		my $self    = shift;
		my $bad_msg = shift;
		my $error   = shift;
		
		print STDERR "bad_message_handler: '$error' (bad_msg: $bad_msg)\n";
		$self->send_message({ msg => MSG_INTERNAL_ERROR, error => $error, bad_msg => $bad_msg });
	}

	sub node_info { shift->{node_info} }

	sub create_envelope
	{
		my $self = shift;
		my $data = shift;

		@_ = %{ $_[0] || {} } if @_ == 1 && ref $_[0] eq 'HASH';

		@_ =  ( to => $_[0] ) if @_ == 1;
		
		my %opts = @_;

		if(!$opts{to} && $self->peer)
		{
			$opts{to} = $self->peer_uuid;
		}

		if(!$opts{nxthop} && $self->peer)
		{
			$opts{nxthop} = $self->peer_uuid;
		}

		if(!$opts{to} && $opts{nxthop})
		{
			$opts{to} = $opts{nxthop};
		}

		if(!$opts{to})
		{
			#print STDERR Dumper $self;
			Carp::cluck "create_envelope: No destination given (either no to=>X, no 2nd arg, or no self->peer), therefore no envelope created";
			return undef;
		}

		if(!$opts{from})
		{
			$opts{from} = $self->node_info->{uuid};
		}

		if(!$opts{curhop})
		{
			$opts{curhop} = $self->node_info->{uuid};
		}

		$opts{hist} = [] if !$opts{hist};

		push @{$opts{hist}},
		{
			from => $opts{curhop} || $opts{from}, #$self->node_info->{uuid},
			to   => $opts{nxthop} || $opts{to},
			time => time(),
		};
		

		my $env =
		{
			time	=> time(),
			uuid	=> $opts{uuid} || $UUID_GEN->generate_v1->as_string(),
			# From is the hub/client where this envelope originated
			from    => $opts{from},
			# To is the hub/client where this envelope is destined
			to	=> $opts{to},
			# Nxthop is the next hub/client this envelope is destined for
			nxthop	=> $opts{nxthop}, # || $opts{to},
			# Curhop is this current client
			curhop	=> $opts{curhop}, # || $opts{from},
			# If bcast is true, the next hub that gets this envelope
			# will copy it and broadcast it to each of its hubs/clients
			bcast	=> $opts{bcast} || 0,
			# If false, the hub will not store it if the client/hub is currently offline - just drops the envelope
			sfwd	=> defined $opts{sfwd} ? $opts{sfwd} : 1, # store n forward
			# Type is only relevant for internal types to SocketWorker - MSG_USER are just put into the incoming queue for the hub to route
			type	=> $opts{type} || MSG_USER,
			# Data is the actual content of the message
			data	=> $data,
			# _att is handled specially by the underlying MessageSocketBase class - it's never encoded to JSON,
			# it's just transmitted raw as an 'attachment' to the JSON message (this envelope) - it's removed from the envelope,
			# transmitted (envelope as JSON, _att as raw data), then re-added to the envelope at the other end in the _att key on that side
			_att	=> $opts{_att} || undef,
			# History of where this envelope/data has been
			hist	=> clean_ref($opts{hist}),
				# use clean_ref because history was getting changed by future calls to create_envelope() for broadcast messages to other hosts
		};

		return $env;
	}

	sub check_env_hist
	{
		my $env = shift;
		my $to = shift;
		return if !ref $env;

		my @hist = @{$env->{hist} || []};
		@hist = @hist[0..$#hist-1]; # last line of hist is the line for X->(this server), so ignore it
		#warn Dumper \@hist;
		foreach my $line (@hist)
		{
			return 1 if $line->{to} eq $to;
		}
		return 0;
	}
	
	sub connect_handler
	{
		my $self = shift;
		
		trace "SocketWorker: Sending MSG_NODE_INFO\n";
		my $env = $self->create_envelope($self->{node_info}, to => '*', type => MSG_NODE_INFO);
		#use Data::Dumper;
		#print STDERR Dumper $env;
		$self->send_message($env);

		$self->state_update(1);
		$self->state_handle->{started} = 0.5;
		$self->state_update(1);
	}

	
	sub disconnect_handler
	{
		my $self = shift;
		
		trace "SocketWorker: disconnect_handler: Peer {".$self->peer_uuid."} disconnected\n"; #peer: $self->{peer}\n";
		print STDERR "\n\n\n\n\n";
		$self->{peer}->set_online(0) if $self->{peer};
	}
	
	sub dispatch_message
	{
		my $self = shift;
		my $envelope = shift;
		my $second_part = shift;
		
		#print STDERR "dispatch_message: envelope: ".Dumper($envelope)."\n";
		
		#$self->send_message({ received => $envelope });
		my $msg_type = $envelope->{type};
		
		if($msg_type eq MSG_ACK)
		{
			# Just ignore ACKs for now
		}
		elsif($msg_type eq MSG_NODE_INFO)
		{
			my $node_info = $envelope->{data};
			info "SocketWorker: dispatch_msg: Received MSG_NODE_INFO for remote node '$node_info->{name}'\n";

			$self->state_update(1);
			$self->state_handle->{remote_node_info} = $node_info;
			$self->state_update(0);
			
			my $peer;
			if(!$self->{peer} &&
			    $self->{peer_host})
			{
				$self->{peer} = HashNet::MP::PeerList->get_peer_by_host($self->{peer_host});
			}
			
			if($self->{peer})
			{
				$peer = $self->peer;
				$peer->merge_keys(clean_ref($node_info));
			}
			else
			{
				$peer = HashNet::MP::PeerList->get_peer_by_uuid(clean_ref($node_info));
				$self->{peer} = $peer;
			}

			#print STDERR Dumper $peer, $node_info;
			
			$peer->set_online(1);

			$self->send_message($self->create_envelope({ack_msg => MSG_NODE_INFO, text => "Hello, $node_info->{name}" }, type => MSG_ACK));

			$self->state_update(1);
			$self->state_handle->{started} = 1;
			$self->state_update(0);
		}
		else
		{
			if(check_env_hist($envelope, $self->node_info->{uuid}))
			{
				info "SocketWorker: dispatch_msg: NOT enquing envelope, history says it was already sent here.\n"; #: ".Dumper($envelope);
			}
			else
			{
				$envelope->{_att} = $second_part if defined $second_part;
				incoming_queue()->add_row($envelope);
				#info "SocketWorker: dispatch_msg: New incoming envelope added to queue: ".Dumper($envelope);
				info "SocketWorker: dispatch_msg: New incoming envelope, UUID {$envelope->{uuid}}, Data: '$envelope->{data}'\n";
				#print STDERR Dumper $envelope;
			}
		}
	}

	sub wait_for_start
	{
		my $self = shift;
		my $max   = shift || 4;
		my $speed = shift || 0.1;
		#trace "SocketWorker: wait_for_start: Enter: ".$self->state_handle->{started}."\n";
		my $time  = time;
		sleep $speed while time - $time < $max and
			     $self->state_handle->{started} != 1;

		# Return 1 if started, or <1 if not yet completely started
		my $res = $self->state_handle->{started};
		#trace "SocketWorker: wait_for_start: Exit, res: $res\n";
		return $res;
	}

	sub wait_for_send
	{
		my $self  = shift;
		my $max   = shift || 4;
		my $speed = shift || 0.1;
		my $uuid  = $self->peer_uuid;
		my $queue = outgoing_queue();
		my $res = defined $queue->by_field(nxthop => $uuid) ? 0 : 1;
		#trace "SocketWorker: wait_for_send: Enter, res: $res\n";
		my $time  = time;
		sleep $speed while time - $time < $max and
		                   defined $queue->by_field(nxthop => $uuid);
		# Returns 1 if all msgs sent by end of $max, or 0 if msgs still pending
		$res = defined $queue->by_field(nxthop => $uuid) ? 0 : 1;
		#trace "SocketWorker: wait_for_send: Exit, res: $res\n";
		#trace "SocketWorker: wait_for_send: All messages sent.\n" if $res;
		return $res;
	}
	
	sub peer { shift->{peer} }
	sub peer_uuid { shift->state_handle->{remote_node_info}->{uuid} }
	
	# Returns a list of pending messages to send using send_message() in process_loop
	use Data::Dumper;
	sub pending_messages
	{
		my $self = shift;
 		return () if !$self->peer;

 		my $uuid  = $self->peer->uuid;
		my @res = HashNet::MP::MessageQueues->pending_messages(outgoing, nxthop => $uuid);
		#trace "SocketWorker: pending_messages: uuid: $uuid, ".Dumper(\@res);
		return @res;
	}
};

1;
