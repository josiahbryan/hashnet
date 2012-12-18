{package HashNet::MP::ClientHandle;

	use common::sense;
	
	use HashNet::MP::PeerList;
	use HashNet::MP::MessageQueues;
	use HashNet::Util::Logging;
	use HashNet::Util::CleanRef;
	use Data::Dumper;

	sub new
	{
		my $class = shift;
		my $host  = shift;
		my $port  = shift || undef;

		my $peer = HashNet::MP::PeerList->get_peer_by_host($port ? "$host:$port" : $host);
		my $worker = $peer->open_connection();

		return bless {
			sw   => $worker,
			peer => $peer,
		}, $class;	
	};

	sub wait_for_start { shift->sw->wait_for_start }
	sub stop { shift->sw->stop }

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
			}
			$opts{to} = $self->sw->state_handle->{remote_node_info}->{uuid}; #$self->peer->uuid;
		}
		
		if(!$opts{nxthop})
		{
			if(!$self->wait_for_start)
			{
				warn "send_message: wait_for_start() failed";
			}
			$opts{nxthop} = $self->sw->state_handle->{remote_node_info}->{uuid}; #$self->peer->uuid;
		}

		#debug "ClientHandle: create_envelope \%opts: ".Dumper(\%opts);
		
		my $env = $self->sw->create_envelope($data, %opts);

		#debug "ClientHandle: Created envelope: ".Dumper($env);
		
		if($env)
		{
			$self->sw->outgoing_queue->add_row($env);
			
			$self->sw->wait_for_send if $flush;
		}
		else
		{
			warn "send_message: Error creating envelope";
		}
	}
	
 	sub incoming_messages
	{
		my $self = shift;
		return pending_messages(incoming, to => $self->uuid);
	}

	sub wait_for_receive
	{
		my $self  = shift;
		my $max   = shift || 4;
		my $speed = shift || 0.01;
		#trace "ClientHandle: wait_for_receive: Enter\n";
		my $uuid  = $self->uuid;
		my $queue = incoming_queue();
		my $time  = time;
		sleep $speed while time - $time < $max
		                   and ! ( defined $queue->by_field(to => $uuid) );
		# Returns 1 if at least one msg received, 0 if incoming queue empty
		my $res = defined $queue->by_field(to => $uuid) ? 1 : 0;
		#trace "ClientHandle: wait_for_receive: Exit, res: $res\n";
		#trace "ClientHandle: wait_for_receive: All messages sent.\n" if $res;
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
