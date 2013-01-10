{package HashNet::MP::Peer;
	
	use common::sense;
	use Data::Dumper;
	use IO::Socket;

	use HashNet::MP::SocketWorker;
	use HashNet::Util::Logging;

	sub from_hash
	{
		my $class = shift;
		my $data = shift;
		
		my $self = bless $data, $class;
		
		#debug "Peer: New peer from hash, self: ".Dumper($data);
		
		return $self;
	}
	
	sub type { shift->{type} }
	sub uuid { shift->{uuid} }
	sub host { shift->{host} }
	
	sub is_online
	{
		my $self = shift;
		$self->load_changes;
		return $self->{online};
	}
	
	sub load_changes
	{
		my $self = shift;
		
		my $data = HashNet::MP::PeerList->get_peer_data_by_uuid($self->uuid);
		$self->merge_keys($data, 1); # 1 = dont re-update database because we just got $data from the DB!
	}
	
	sub set_online
	{
		my $self  = shift;
		my $value = shift;
		
		$self->{online} = $value;

		HashNet::MP::PeerList->update_peer($self);
		
		return $value;
	}
	
	sub merge_keys
	{
		my $self = shift;
		my $data = shift;
		my $no_update = shift;
		return undef if ref $data ne 'HASH';
		
		foreach my $key (keys %{$data ||{}})
		{
			$self->{$key} = $data->{$key};
		}

		#debug "Peer: merge_keys: Dump of self: ".Dumper($self);

		HashNet::MP::PeerList->update_peer($self) unless $no_update;
		
		return $self;
	}
	
	sub _open_socket
	{
		my $self = shift;
		my $host = $self->{host};
		return undef if !$host;
		
		my $port = 8031;
		if($host =~ /^(.*?):(\d+)$/)
		{
			$host = $1;
			$port = $2;
		}
		
		# create a tcp connection to the specified host and port
		my $handle = IO::Socket::INET->new(Proto     => "tcp",
						PeerAddr  => $host,
						PeerPort  => $port);
		if(!$handle)
		{
			error "Peer: _open_socket: Can't connect to port $port on $host: $!\n";
			return undef;
		}
		
		$handle->autoflush(1); # so output gets there right away
		
		return $handle;
	}
	
	sub open_connection
	{
		my $self = shift;
		my $node_info = shift || undef;
		
		my $sock = $self->_open_socket();
		if($sock)
		{
			return HashNet::MP::SocketWorker->new(
				sock		=> $sock,
				peer_host	=> $self->{host},
				node_info	=> $node_info,
			); # forks off new worker
		}
		else
		{
			#warn "Peer: open_connection: Cannot connect to '$self->{host}'\n";
			return undef;
		}
	}
};

1;