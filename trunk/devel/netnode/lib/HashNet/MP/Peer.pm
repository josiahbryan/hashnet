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

		

		if($host =~ /^sshtun:(.*?):(.*?)@(.*?)\/(.*?):(.*)$/)
		{
			# Example: sshtun:root:+rootpw.txt@mypleasanthillchurch.org/localhost:8031
			my %args = (
				user 	=> $1,
				pass	=> $2,
				tunhost	=> $3,
				host	=> $4,
				port	=> $5
			);

			if($args{pass} =~ /^\+(.*)$/)
			{
				my $file = $1;
				warn "Peer: _open_socket: sshtun: Password file '$file' does not exist" if !-f $file;
				$args{pass} = read_file($file);
				$args{pass} =~ s/[\r\n]//g;
			}

			my $local_port = 60000;
			$local_port ++ while $local_port < 65536 and `lsof -i :$local_port`;
			if($local_port == 65536)
			{
				error "Peer: _open_socket: sshtun: Cannot find an open port for the local end of the tunnel\n";
			}

			$host = "localhost:${local_port}";

			use HashNet::Util::MyNetSSHExpect;

			my $ssh_tun_arg = "-L$local_port:$args{host}:$args{port}";

			trace "Peer: _open_socket: Opening SSH tunnel via $args{tunhost} to $args{host}:$args{port}, local port $local_port\n";
			debug "Peer: _open_socket: \$ssh_tun_arg: '$ssh_tun_arg'\n";

			$self->{ssh_handle} = Net::SSH::Expect->new (
				host		=> $args{tunhost},
				password	=> $args{user},
				user		=> $args{pass},
				raw_pty		=> 1,
				ssh_option	=> $ssh_tun_arg,
			);

			$self->{ssh_handle}->login();
		}
		
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

	sub DESTROY
	{
		my $self = shift;
		$self->{ssh_handle}->close() if $self->{ssh_handle};
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