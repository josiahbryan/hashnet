{package HashNet::MP::Peer;
	
	use common::sense;
	use Data::Dumper;

	sub from_hash
	{
		my $class = shift;
		my $data = shift;
		
		my $self = bless $data, $class;
		
		#print STDERR "Peer: New peer from hash, self: ".Dumper($data);
		
		return $self;
	}
	
	sub type { shift->{type} }
	sub uuid { shift->{uuid} }
	sub host { shift->{host} }
	
	sub is_online { shift->{online} }
	
	sub set_online
	{
		my $self  = shift;
		my $value = shift;
		
		$self->{online} = $value;
		
		return $value;
	}
	
	sub merge_keys
	{
		my $self = shift;
		my $data = shift;
		return undef if ref $data ne 'HASH';
		
		foreach my $key (keys %{$data ||{}})
		{
			$self->{$key} = $data->{$key};
		}
		
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
			warn "MessageHub: _get_socket: Can't connect to port $port on $host: $!";
			return undef;
		}
		
		$handle->autoflush(1); # so output gets there right away
		
		return $handle;
	}
	
	sub open_connection
	{
		my $self = shift;
		my $hub = shift;
		
		my $sock = $self->_open_socket();
		if($sock)
		{
			return HashNet::MP::SocketWorker->new(
				sock	=> $sock,
				peer	=> $self,
				term	=> $hub,
				node_info => $hub->node_info,
			); # forks off new worker
		}
		else
		{
			warn "Peer: open_connection: Cannot connect to '$self->{host}'\n";
		}
	}
};

1;