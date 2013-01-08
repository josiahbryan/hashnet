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
			send_receipts => 1,
		}, $class;	
	};

	sub sw			{ shift->{sw} }
	sub peer		{ shift->{peer} }

	sub send_ping		{ shift->sw->send_ping(@_) }
	
	sub wait_for_start	{ shift->sw->wait_for_start(@_)   }
	sub wait_for_send	{ shift->sw->wait_for_send(@_)    }
	sub wait_for_receive	{ shift->sw->wait_for_receive(@_) }
	sub stop		{ shift->sw->stop }

	sub uuid 		{ shift->sw->node_info->{uuid} }
	sub peer_uuid		{ shift->sw->state_handle->{remote_node_info}->{uuid} }
	
	sub DESTROY
	{
		my $self = shift;

		$self->stop;
	}
	
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
	
 	sub incoming_messages
	{
		my $self = shift;

		$self->outgoing_queue->begin_batch_update;

		# Check 'to' and not 'nxthop' because msgs could reach us
		# that are not broadcast and not to us - they just
		# got sent to our socket because the hub didn't know where the client was
		# connected - so we dont want the client to work with those messages
		my @msgs = pending_messages(incoming, to => $self->uuid, no_del => 1);

		if($self->{send_receipts})
		{
			my $sw = $self->sw;

			foreach my $msg (@msgs)
			{
				my $new_env = $sw->create_client_receipt($msg);
				#trace "ClientHandle: incoming_messages: Created MSG_CLIENT_RECEIPT for {$msg->{uuid}}\n";#, data: '$msg->{data}'\n"; #: ".Dumper($new_env, \@args)."\n";
				$self->enqueue($new_env);
			}

			$self->outgoing_queue->end_batch_update;

			# Wait for all the MSG_CLIENT_RECEIPTs to transmit before deleting the messages
			# from the incoming queue and returning to caller so that we can be assured
			# that receipts are sent
			$self->sw->wait_for_send if @msgs;
		}

		$self->incoming_queue->del_batch(\@msgs);

		return @msgs;
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
