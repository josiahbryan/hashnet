{package HashNet::MP::ClientHandle;

	use common::sense;
	
	use HashNet::MP::PeerList;
	use HashNet::MP::MessageQueues;
	use HashNet::Util::Logging;
	use HashNet::Util::CleanRef;
	use Data::Dumper;

	sub MSG_CLIENT_RECEIPT { 'MSG_CLIENT_RECEIPT' }

	sub connect
	{
		my $class = shift;
		my $host  = shift;
		#my $port  = shift || undef;
		my $node_info = shift || undef;

		#my $peer = HashNet::MP::PeerList->get_peer_by_host($port ? "$host:$port" : $host);
		my $peer = HashNet::MP::PeerList->get_peer_by_host($host);
		my $worker = $peer->open_connection($node_info);
		if(!$worker)
		{
			#die "Unable to connect to $host";
			return undef;
		}

		return bless {
			sw   => $worker,
			peer => $peer,
		}, $class;	
	};

	sub wait_for_start { shift->sw->wait_for_start(@_) }
	sub wait_for_send  { shift->sw->wait_for_send(@_)  }
	sub stop           { shift->sw->stop }

	sub uuid { shift->sw->node_info->{uuid} }

	sub DESTROY
	{
		my $self = shift;

		$self->stop;
	}

	sub sw { shift->{sw} }
	sub peer { shift->{peer} }
	
	sub send
	{
		my $self  = shift;
		my $data  = shift || undef;
		my %opts  = @_;

		my $flush = 1;
		if(defined $opts{flush})
		{
			# delete opts{flush} because we flush, not create_envelope
			$flush = $opts{flush};
			delete $opts{flush};
		}
		
		if(!$opts{to})
		{
			if(!$self->wait_for_start)
			{
				warn "send_message: wait_for_start() failed";
				return 0;
			}
			$opts{to} = $self->peer_uuid; #$self->peer->uuid;
		}
		
		if(!$opts{nxthop})
		{
			if(!$self->wait_for_start)
			{
				warn "send_message: wait_for_start() failed";
				return 0;
			}
			$opts{nxthop} = $self->peer_uuid; #$self->peer->uuid;
		}

		#debug "ClientHandle: create_envelope \%opts: ".Dumper(\%opts);
		
		my $env = $self->sw->create_envelope($data, %opts);

		#debug "ClientHandle: Created envelope: ".Dumper($env);
		
		if($env)
		{
			#info "ClientHandle: Sending '$env->{data}' to '$env->{to}'\n";
			$self->enqueue($env, $flush);
		}
		else
		{
			warn "send_message: Error creating envelope";
		}

		return 1;
	}

	sub enqueue
	{
		my ($self, $env, $flush) = @_;
		
		$self->sw->outgoing_queue->add_row($env);
		$self->sw->wait_for_send if $flush;
	}

	sub peer_uuid
	{
		shift->sw->state_handle->{remote_node_info}->{uuid};
	}
	
 	sub incoming_messages
	{
		my $self = shift;

		$self->outgoing_queue->pause_update_saves;

		# Check 'to' and not 'nxthop' because msgs could reach us
		# that are not broadcast and not to us - they just
		# got sent to our socket because the hub didn't know where the client was
		# connected - so we dont want the client to work with those messages
		my @msgs = pending_messages(incoming, to => $self->uuid, no_del => 1);

		my $sw = $self->sw;

		foreach my $msg (@msgs)
		{
			my @args =
			(
				{
					msg_uuid    => $msg->{uuid},
					msg_hist    => $msg->{hist},
					client_uuid => $self->uuid,
				},
				type	=> MSG_CLIENT_RECEIPT,
				nxthop	=> $self->peer_uuid,
				curhop	=> $self->uuid,
				to	=> '*',
				bcast	=> 1,
				sfwd	=> 0,
			);
			my $new_env = $sw->create_envelope(@args);
			#trace "ClientHandle: incoming_messages: Created MSG_CLIENT_RECEIPT for {$msg->{uuid}}\n";#, data: '$msg->{data}'\n"; #: ".Dumper($new_env, \@args)."\n";
			$self->enqueue($new_env);
		}

		$self->outgoing_queue->resume_update_saves;

		# Wait for all the MSG_CLIENT_RECEIPTs to transmit before deleting the messages
		# from the incoming queue and returning to caller so that we can be assured
		# that receipts are sent
		$self->sw->wait_for_send if @msgs;

		$self->incoming_queue->del_batch(\@msgs);

		return @msgs;
	}

	sub wait_for_receive
	{
		my $self  = shift;
		my $count = shift || 1;
		my $max   = shift || 4;
		my $speed = shift || 0.01;
		my $uuid  = $self->uuid;
		#trace "ClientHandle: wait_for_receive: Enter (to => $uuid), count: $count, max: $max, speed: $speed\n";
		my $queue = incoming_queue();
		my $time  = time;
		sleep $speed while time - $time < $max
		               and scalar ( $queue->all_by_key(to => $uuid) ) < $count;
# 		while(time - $time < $max)
# 		{
# 			my $cnt = scalar ( $queue->all_by_key(to => $uuid) );
# 			#trace "ClientHandle: wait_for_receive: Have $cnt, want $count ...\n";
# 			last if $cnt >= $count;
# 		}
		
		# Returns 1 if at least one msg received, 0 if incoming queue empty
		my $res = scalar $queue->all_by_key(to => $uuid);
		#trace "ClientHandle: wait_for_receive: Exit, res: $res\n";
		#print STDERR "ClientHandle: Dumper of queue: ".Dumper($queue);
		#trace "ClientHandle: wait_for_receive: All messages received.\n" if $res;
		return $res;
	}

	sub messages
	{
		my $self = shift;
		my $wait_flag = shift;
		$wait_flag = 1 if ! defined $wait_flag;
		$self->wait_for_receive(@_) if $wait_flag;
		return $self->incoming_messages;
	}
};
1;
