{package HashNet::MP::ClientHandle;

	use common::sense;
	
	use HashNet::MP::PeerList;

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
		my $opts  = shift || {};
		my $flush = shift;
		$flush = 1 if !defined $flush;
		
		if(!$opts->{to})
		{
			if(!$self->wait_for_start)
			{
				warn "send_message: wait_for_start() failed";
			}
			$opts->{to} = $self->sw->state_handle->{remote_node_info}->{uuid}; #$self->peer->uuid;
		}
		
		my $env = $self->sw->create_envelope($data, $opts);
		
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


};
1;
