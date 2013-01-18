{package HashNet::MP::Peer;
	
	use common::sense;
	use Data::Dumper;
	use IO::Socket;
	use File::Slurp;
	use Time::HiRes qw/sleep time/;

	use HashNet::MP::SocketWorker;
	use HashNet::Util::Logging;
	use HashNet::Util::MyNetSSHExpect; # for ssh tunnels

	our $LOCALPORT_DB = ".sshtun.portnums";
	
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
			    can_signal($self->{worker_pid});

		# Keep state consitent
		if($self->{worker_pid})
		{
			$self->close_tunnel();
			log_kill($self->{worker_pid});
		}
		
		return 0;
	}

	sub is_connecting
	{
		my $self = shift;
		$self->load_changes;

		if($self->{connecting_pid} &&
		   $self->{connecting} &&
		   can_signal($self->{connecting_pid}))
		{
			# Connecting is VALID, but check for timeout
			if(time - $self->{connecting_time} > 60) # arbitrary time
			{
				# No effect if no tun
				$self->close_tunnel();

				# No return here, fall thru to the log_kill(...) below
			}
			else
			{
				return 1;
			}	
		}

		# Keep state consitent
		if($self->{connecting_pid} &&
		  !$self->is_online)
		{
			log_kill($self->{connecting_pid});
		}
		
		return 0;
	}
	
	sub load_changes
	{
		my $self = shift;
		
		return if !HashNet::MP::PeerList->has_external_changes;
		my $data = HashNet::MP::PeerList->get_peer_data_by_uuid($self->uuid);
		$self->merge_keys($data, 1); # 1 = dont re-update database because we just got $data from the DB!
	}
	
	sub set_online
	{
		my $self  = shift;
		my $value = shift;
		my $pid   = shift;
		
		$self->{online} = $value;
		$self->{connecting} = 0;
		
		$self->{worker_pid} = $pid if $pid;
		delete $self->{worker_pid} if !$pid;

		HashNet::MP::PeerList->update_peer($self);
		
		return $value;
	}
	
	sub set_connecting
	{
		my $self  = shift;
		my $value = shift;
		my $pid   = shift;

		$self->{online} = 0;
		$self->{connecting} = $value;

		$self->{connecting_time} = time if $value;
		
		$self->{connecting_pid} = $pid if $pid;
		delete $self->{connecting_pid} if !$pid;

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

			my $local_port = 0;

			my $shref = HashNet::MP::SharedRef->new($LOCALPORT_DB);
			$shref->lock_file;
			$shref->update_begin;

			for my $port (3729 .. 65536)
			{
				next if qx{ lsof -i :$port };
				if(my $data = $shref->{inuse}->{$port})
				{
					my $other_peer = HashNet::MP::PeerList->get_peer_by_id($data->{id});
					if($other_peer)
					{
						if($other_peer->{id} != $self->{id})
						{
							my $min_check_time = 60; # # seconds
							if(time - $data->{timestamp} < $min_check_time)
							{
								debug "Peer: _open_tunnel: Port $port open, but other peer '$other_peer->{name}' (ID $data->{id}) is within the safety window for this port\n";
								next;
							}

							if($other_peer->is_online) # is_online() checks PID as well
							{
								debug "Peer: _open_tunnel: Port $port open, but other peer '$other_peer->{name}' (ID $data->{id}) is online\n";
								next;
							}
						}

						# Port was marked as inuse, but didnt pass checks, so delete data and we'll use it
						delete $shref->{inuse}->{$port};
					}
				}

				debug "Peer: _open_tunnel: Found open local port $port, using for tunnel\n";

				$local_port = $port;
				$shref->{inuse}->{$port} = { id=> $self->{id}, timestamp => time() };

				last;
			}

			#trace "Peer: _open_tunnel: Writing data to ".$shref->file.": ".Dumper($shref)."\n";
			$shref->update_end;
			$shref->unlock_file;
			#trace "Peer: _open_tunnel: Writing data to ".$shref->file." done\n";

			if(!$local_port)
			{
				die "Peer: _open_tunnel: sshtun: Cannot find an open port for the local end of the tunnel";
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

				$shref->update_begin;
				trace "Peer: _open_tunnel: Stored tunnel pid $$ for $orighost\n";
				log_kill($shref->{tunnel_pids}->{$orighost}) if $shref->{tunnel_pids}->{$orighost};
				$shref->{tunnel_pids}->{$orighost} = $$;
				$shref->update_end;

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
		return $self->{tunnel_pid} if $self->{tunnel_pid} && can_signal($self->{tunnel_pid});
		return 0;
	}

	sub close_tunnel
	{
		my $self = shift;
		if($self->has_tunnel())
		{
			trace "Peer: close_tunnel: Closing tunnel thread $self->{tunnel_pid}\n";
			log_kill($self->{tunnel_pid}) if $self->{tunnel_pid};

			delete $self->{tunnel_pid};
		}
	}

	sub _open_socket
	{
		my $self = shift;

		# Make sure we reflect our state correctly
		$self->set_online(0);
		$self->set_connecting(1, $$);

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