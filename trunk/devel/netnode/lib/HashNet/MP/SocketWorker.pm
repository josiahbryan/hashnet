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
	sub MSG_OFFLINE		{ 'MSG_OFFLINE' }
	sub MSG_PING		{ 'MSG_PING' }
	sub MSG_PONG		{ 'MSG_PONG' }
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

# 		my $env = $self->create_envelope($self->{node_info}->{name}.' Shutdown',
# 						to => '*',
# 						sfwd => 0,
# 						bcast => 1,
# 						type => MSG_OFFLINE);
# 		$self->send_message($env);
		#print STDERR Dumper $env;

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
		$self->state_handle->{online} = 0.5;
		$self->state_update(0);
	}

	
	sub disconnect_handler
	{
		my $self = shift;
		
		trace "SocketWorker: disconnect_handler: Peer {".$self->peer_uuid."} disconnected\n\n\n\n\n\n"; #peer: $self->{peer}\n";
		#print STDERR "\n\n\n\n\n";
		$self->{peer}->set_online(0) if $self->{peer};

		$self->state_update(1);
		$self->state_handle->{online} = 0;
		$self->state_update(0);
	}
	
	sub dispatch_message
	{
		my $self = shift;
		my $envelope = shift;
		my $second_part = shift;
		
		#print STDERR "dispatch_message: envelope: ".Dumper($envelope)."\n";
		
		#$self->send_message({ received => $envelope });
		my $msg_type = $envelope->{type};

		if($msg_type eq MSG_PING)
		{
			if(check_env_hist($envelope, $self->node_info->{uuid}))
			{
				info "SocketWorker: dispatch_msg: MSG_PING: Ignoring this ping, it's been here before\n";
			}
			elsif($envelope->{from} eq $self->node_info->{uuid})
			{
				info "SocketWorker: dispatch_msg: MSG_PING: Not responding to self-ping\n";
			}
			else
			{
				my @args =
				(
					{
						msg_uuid    => $envelope->{uuid},
						msg_hist    => $envelope->{hist},
						node_info   => $self->node_info,
						pong_time   => time(),
					},
					type	=> MSG_PONG,
					nxthop	=> $self->peer_uuid,
					curhop	=> $self->node_info->{uuid},
					to	=> $envelope->{from},
					bcast	=> 0,
					sfwd	=> 1,
				);
				my $new_env = $self->create_envelope(@args);
				#trace "ClientHandle: incoming_messages: Created MSG_PONG for {$envelope->{uuid}}\n";#, data: '$msg->{data}'\n"; #: ".Dumper($new_env, \@args)."\n";
				my $delta = $new_env->{data}->{pong_time} - $envelope->{data}->{ping_time};
				info "SocketWorker: dispatch_msg: MSG_PING, UUID {$envelope->{uuid}}, sending MSG_PONG back to {$envelope->{from}} ($envelope->{data}->{node_info}->{name}), ping->pong time: ".sprintf('%.03f', $delta)." sec\n";

				#use Data::Dumper;
				#print STDERR Dumper $envelope;

				$self->send_message($new_env);
			}
		}
		# We let MSG_PINGs fall thru to be dropped in the incoming queue as well so they can be processed by the MessageHub
		
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
			$self->state_handle->{online} = 1;
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
				$envelope->{_rx_time} = time();
				incoming_queue()->add_row($envelope);
				#info "SocketWorker: dispatch_msg: New incoming envelope added to queue: ".Dumper($envelope);
				info "SocketWorker: dispatch_msg: New incoming $envelope->{type} envelope, UUID {$envelope->{uuid}}, Data: '$envelope->{data}'\n";
				#print STDERR Dumper $envelope;
			}
		}
	}

	sub bulk_read_start_hook
	{
		incoming_queue()->pause_update_saves;
	}
	
	sub bulk_read_end_hook
	{
		incoming_queue()->resume_update_saves;
	}

	sub send_ping
	{
		my $self = shift;
		my $uuid_to = shift;
		my $max   = shift || 5;
		my $speed = shift || 0.01;

		my $start_time = time();
		my $bcast = $uuid_to ? 0 : 1;

		$self->wait_for_start if !$self->is_started;

		my @args =
		(
			{
				node_info   => $self->node_info,
				ping_time   => $start_time,
			},
			type	=> MSG_PING,
			nxthop	=> $self->peer_uuid,
			curhop	=> $self->node_info->{uuid},
			to	=> $uuid_to || '*',
			bcast	=> $bcast,
			sfwd	=> 1,
		);
		my $new_env = $self->create_envelope(@args);

		info "SocketWorker: send_ping: Sending MSG_PING" . ($uuid_to ? " to $uuid_to" : " as a broadcast ping"). " via hub ".$self->peer_uuid." (".$self->state_handle->{remote_node_info}->{name}.")\n";
		
		$self->send_message($new_env);

		#$self->outgoing_queue->add_row($new_env);
		#$self->wait_for_send();

		my $uuid  = $self->node_info->{uuid};
		my $queue = incoming_queue();
		if(!$bcast)
		{
			# Wait for a single pong back
			my $time  = time;
			while(time - $time < $max)
			{
				my $flag = defined ( $queue->by_key(to => $uuid, type => 'MSG_PONG') );
				if(!$self->state_handle->{online})
				{
					error "SocketWorker: wait_for_receive; SocketWorker dead or dieing, not waiting anymore\n";
					last;
				}

				#trace "SocketWorker: wait_for_receive: Have $cnt, want $count ...\n";
				last if $flag;
				sleep $speed;
			}
		}
		else
		{
			# Just wait for broadcast pings to come in
			sleep $max;
		}

		my @list = $queue->by_key(to => $uuid, type => 'MSG_PONG');
		@list = sort { $a->{time} cmp $b->{time} } @list;

		my @return_list = map { clean_ref($_) } grep { defined $_ } @list;

		$queue->del_batch(\@list);

		my $final_rx_time = time();

		if(!$bcast)
		{
			return undef if !@return_list;
			my $msg = shift @return_list;
			my $pong_time = $msg->{data}->{pong_time};
			my $delta = $pong_time - $start_time;
			my $rx_delta = $final_rx_time - $start_time;
			info "SocketWorker: Ping $uuid_to: ".sprintf('%.03f', $delta)." sec (total tx/rx time: ".sprintf('%.03f', $rx_delta)." sec)\n";
			return $delta;
		}
		else
		{
			return () if !@return_list;

			my $rx_delta = $final_rx_time - $start_time;
			my @output;
			foreach my $msg (@return_list)
			{
				my $pong_time = $msg->{data}->{pong_time};
				my $delta = $pong_time - $start_time;

				my $out =
				{
					msg       => $msg,
					node_info => $msg->{data}->{node_info},
					time      => $delta,
					rx_delta  => $rx_delta,
				};

				push @output, $out;
				info "SocketWorker: Broadcast Ping: ".sprintf('%.03f', $delta)." sec to {$out->{node_info}->{uuid}} '$out->{node_info}->{name}'\n";
			}

			return @output;
		}
	}
	

	sub is_started { shift->state_handle->{online} == 1 }
	
	sub wait_for_start
	{
		my $self = shift;
		my $max   = shift || 4;
		my $speed = shift || 0.1;
		#trace "SocketWorker: wait_for_start: Enter: ".$self->state_handle->{started}."\n";
		my $time  = time;
		sleep $speed while time - $time < $max and
			     $self->state_handle->{online} != 1;

		# Return 1 if started, or <1 if not yet completely started
		my $res = $self->state_handle->{online};
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
		sleep $speed while time - $time < $max
			       #and !$queue->has_external_changes # check is_changed first to prevent having to re-load data every time if nothing changed
		               and defined $queue->by_field(nxthop => $uuid);
		# Returns 1 if all msgs sent by end of $max, or 0 if msgs still pending
		$res = defined $queue->by_field(nxthop => $uuid) ? 0 : 1;
		#trace "SocketWorker: wait_for_send: Exit, res: $res\n";
		#trace "SocketWorker: wait_for_send: All messages sent.\n" if $res;
		return $res;
	}

	sub wait_for_receive
	{
		my $self  = shift;
		my $count = shift || 1;
		my $max   = shift || 4;
		my $speed = shift || 0.01;
		my $uuid  = $self->node_info->{uuid};
		#trace "ClientHandle: wait_for_receive: Enter (to => $uuid), count: $count, max: $max, speed: $speed\n";
		my $queue = incoming_queue();
		my $time  = time;

# 		sleep $speed while time - $time < $max
# 		             and !$queue->has_external_changes;  # check has_external_changes first to prevent having to re-load data every time if nothing changed
#
# 		$queue->shared_ref->load_changes;

		#sleep $speed while time - $time < $max
		#               and scalar ( $queue->all_by_key(to => $uuid) ) < $count;
		while(time - $time < $max)
		{
			my $cnt = scalar ( $queue->all_by_key(to => $uuid) );
			if(!$self->state_handle->{online})
			{
				error "SocketWorker: wait_for_receive; SocketWorker dead or dieing, not waiting anymore\n";
				return $cnt;
			}

			trace "SocketWorker: wait_for_receive: Have $cnt, want $count ...\n";
			last if $cnt >= $count;
			sleep $speed;
		}

		# Returns 1 if at least one msg received, 0 if incoming queue empty
		my $res = scalar $queue->all_by_key(to => $uuid);
		#trace "ClientHandle: wait_for_receive: Exit, res: $res\n";
		#print STDERR "ClientHandle: Dumper of queue: ".Dumper($queue);
		#trace "ClientHandle: wait_for_receive: All messages received.\n" if $res;
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
		my @res = HashNet::MP::MessageQueues->pending_messages(outgoing, nxthop => $uuid, no_del => 1);
		#trace "SocketWorker: pending_messages: uuid: $uuid, ".Dumper(\@res);
		return @res;
	}

	sub messages_sent
	{
		my $self = shift;
		my $batch = shift;
		$self->outgoing_queue->del_batch($batch);
	}
};

1;
