{package HashNet::MP::ClientHandle;

	use common::sense;
	
	use HashNet::MP::PeerList;
	use HashNet::Util::Logging;
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


};
1;
