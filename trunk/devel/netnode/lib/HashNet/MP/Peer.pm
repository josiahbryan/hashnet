{package HashNet::MP::Peer;
	
	use common::sense;
	use Data::Dumper;
	use IO::Socket;
	use File::Slurp;
	use Time::HiRes qw/sleep time/;

	use HashNet::MP::SocketWorker;
	use HashNet::Util::Logging;
	use HashNet::Util::MyNetSSHExpect; # for ssh tunnels
	
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
		return 1 if $self->{worker_pid} &&
		            $self->{online}     &&
			    kill(0, $self->{worker_pid});
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
		my $pid   = shift;
		
		$self->{online} = $value;
		
		$self->{worker_pid} = $pid if $pid;
		delete $self->{worker_pid} if !$pid;

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
	
	sub _open_tunnel
	{
		my ($self, $host) = @_;
		#
		# Example:
		#	sshtun:root:+rootpw.txt@mypleasanthillchurch.org/localhost:8031
		#
		if($host =~ /^sshtun:(.*?):(.*?)@(.*?)\/(.*?):(.*)$/)
		{
			my $orighost = $host;
			
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
				warn "Peer: _open_tunnel: sshtun: Password file '$file' does not exist" if !-f $file;
				$args{pass} = read_file($file);
				$args{pass} =~ s/[\r\n]//g;
			}

			my $local_port = 3729;
			$local_port ++ while $local_port < 65536 and qx{ lsof -i :$local_port };
			if($local_port == 65536)
			{
				warn "Peer: _open_tunnel: sshtun: Cannot find an open port for the local end of the tunnel";
			}

			# This is the host:port we return to the caller, _open_socket,
			# so it can connect to the local side of the tunnel
			$host = "localhost:${local_port}";
			
			my $ssh_tun_arg = "-L $local_port:$args{host}:$args{port}";

			trace "Peer: _open_tunnel: Opening SSH tunnel via $args{tunhost} to $args{host}:$args{port}, local port $local_port\n";
			#debug "Peer: _open_socket: \$ssh_tun_arg: '$ssh_tun_arg'\n";

			my $pid = fork();
			if(!$pid)
			{
				# Isolate the Expect process in its own fork so that
				# if the process that called _open_tunnel dies (e.g. when called in a fork from MessageHub)
				# the tunnel stays up.
				
				$0 = "$0 [Tunnel to $args{host}:$args{port} via $args{tunhost}]";
				my $ssh = Net::SSH::Expect->new (
					host		=> $args{tunhost},
					password	=> $args{pass},
					user		=> $args{user},
					raw_pty		=> 1,
					ssh_option	=> $ssh_tun_arg,
				);
	
				$ssh->login();
				sleep 60 *  60 # minutes
					 *  24 # hours
					 * 365 # days
					 *  10;# years
				exit;
			}
			else
			{
				$self->{tunnel_pid} = $pid;
				HashNet::MP::PeerList->update_peer($self);
			}
			
			my $timeout = 30;
			my $time = time();
			my $speed = 0.5;
			# Wawit for max $timeout seconds if $local_port is not open 
			sleep $speed while time - $time < $timeout and not qx{ lsof -i :${local_port} };
			if(!qx{ lsof -i :${local_port} })
			{
				warn "Peer: _open_tunnel: Local port $local_port for SSH tunnel never opened";	
			}
		}
		
		return $host;
	}
	
	sub has_tunnel
	{
		my $self = shift;
		$self->load_changes();
		return $self->{tunnel_pid} if $self->{tunnel_pid} && kill(0, $self->{tunnel_pid});
		return 0;
	}
	
	sub close_tunnel
	{
		my $self = shift;
		if($self->has_tunnel())
		{
			trace "Peer: close_tunnel: Closing tunnel thread $self->{tunnel_pid}\n";
			kill 15, $self->{tunnel_pid};
			
			delete $self->{tunnel_pid};
		}
	}
	
	sub _open_socket
	{
		my $self = shift;
		
		# Make sure we reflect our state correctly
		$self->set_online(0);
		
		my $host = $self->{host};
		return undef if !$host;

		$host = $self->_open_tunnel($host)
			if $host =~ /^sshtun:/;
		
		my $port = 8031;
		if($host =~ /^(.*?):(\d+)$/)
		{
			$host = $1;
			$port = $2;
		}
		
		# create a tcp connection to the specified host and port
		my $handle = IO::Socket::INET->new(Proto  => "tcp",
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

		#trace "Peer: DESTROY ($self->{name} / $self->{host})\n";
		#local *@;
		#eval { $self->{_ssh_handle}->close() if $self->{_ssh_handle}; }
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