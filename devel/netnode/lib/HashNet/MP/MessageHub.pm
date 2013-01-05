{package HashNet::MP::MessageHub;
	
	use common::sense;

	use base qw/HashNet::MP::SocketTerminator/;
	
	use HashNet::MP::SocketWorker;
	use HashNet::MP::LocalDB;
	use HashNet::MP::PeerList;
	use HashNet::MP::MessageQueues;
	use HashNet::Util::Logging;
	use HashNet::Util::CleanRef;
	use HashNet::Util::ExecTimeout;

	#$HashNet::Util::Logging::ANSI_ENABLED = 1;

	use POSIX;

	use Time::HiRes qw/alarm sleep/;

	use Data::Dumper;
	
	use File::Path qw/mkpath/;

	sub MSG_CLIENT_RECEIPT { 'MSG_CLIENT_RECEIPT' }

	our $DEFAULT_CONFIG_FILE = [qw#hashnet-hub.conf /etc/hashnet-hub.conf#];
	our $DEFAULT_CONFIG =
	{
		port	 => 8031,
		uuid	 => undef,
		name	 => undef,
		data_dir => '/var/lib/hashnet',
	};
	
	my $HUB_INST = undef;
	sub inst
	{
		my $class = shift;
		
		$HUB_INST = $class->new
			if !$HUB_INST;
		
		return $HUB_INST;
	}
	
	sub new
	{
		my $class = shift;
		my %opts = @_;
		
		$opts{auto_start} = 1 if !defined $opts{auto_start};
		
		my $self = bless {}, $class;
		
		$self->{opts} = \%opts;
		
		$self->read_config();
		$self->connect_remote_hubs();

		# Start GlobalDB running and listening for incoming updates
		$self->{globaldb} = HashNet::MP::GlobalDB->new(rx_uuid => $self->node_info->{uuid});
		
		$self->start_router() if $opts{auto_start};
		$self->start_server() if $opts{auto_start};
	}
	
	sub read_config
	{
		my $self = shift;
		my $config = $self->{opts}->{config_file} || $DEFAULT_CONFIG_FILE;
		if(ref $config eq 'ARRAY')
		{
			my @list = @{$config || []};
			undef $config;
			foreach my $file (@list)
			{
				if(-f $file)
				{
					$config = $file;
				}
			}
			if(!$config)
			{
				$self->setup_default_config;
				return;
				
			}
		}
		
		if(!-f $config)
		{
			$self->setup_default_config($config);
		}
		
		open(FILE, "<$config") || die "MessageHub: Cannot read config '$config': $!";
		trace "MessageHub: Reading config from '$config'\n";
		
		my @config;
		push @config, $_ while $_ = <FILE>;
		close(FILE);
		
		foreach my $line (@config)
		{
			$line =~ s/[\r\n]//g;
			$line =~ s/#.*$//g;
			next if !$line;
			
			my ($key, $value) = $line =~ /^\s*(.*?):\s*(.*)$/;
			$self->{config}->{$key} = $value;
		}
		
# 		use Data::Dumper;
# 		print Dumper $self->{opts};
		
		$self->check_config_items();
	}
	
	sub setup_default_config
	{
		my $self = shift;
		my $file = shift || undef;
		
		$DEFAULT_CONFIG->{name} = `hostname`;
		$DEFAULT_CONFIG->{name} =~ s/[\r\n]//g;

		$DEFAULT_CONFIG->{uuid} = `uuidgen`;
		$DEFAULT_CONFIG->{uuid} =~ s/[\r\n]//g;
		
		$DEFAULT_CONFIG->{data_dir} = $self->{data_dir} if $self->{data_dir};
		
		trace "MessageHub: read_config: Unable to find config, using default settings: ".Dumper($DEFAULT_CONFIG);
		$self->{config} = $DEFAULT_CONFIG;
		
		$self->write_default_config($file);
		
		$self->check_config_items();
	}
	
	sub write_default_config
	{
		my $self = shift;
		my $file = shift || undef;
		my $cfg = $self->{config};
		my $file = $file ? $file : (ref $DEFAULT_CONFIG_FILE eq 'ARRAY' ? $DEFAULT_CONFIG_FILE->[0] : $DEFAULT_CONFIG_FILE);
		open(FILE, ">$file") || die "MessageHub: write_default_config: Cannot write to $file: $!";
		print FILE "$_: $cfg->{$_}\n" foreach keys %{$cfg || {}};
		close(FILE);
		trace "MessageHub: Wrote default configuration settings to $file\n";
	}
	
	sub check_config_items
	{
		my $self = shift;
		my $cfg = shift || $self->{config};

		foreach my $key (keys %{$self->{opts} || {}})
		{
			my $val = $self->{opts}->{$key};
			trace "MessageHub: Config option overwritten by script code: '$key' => '$val'\n";
			$cfg->{$key} = $val;
		}
		
		mkpath($cfg->{data_dir}) if !-d $cfg->{data_dir};

		#trace "MessageHub: Config dump: ".Dumper($cfg);
	}
	
	sub connect_remote_hubs
	{
		my $self = shift;
		my @list = HashNet::MP::PeerList->peers_by_type('hub');
		
		#if(!@list)
		#{
			my $seed_hub = $self->{config}->{seed_hubs} || $self->{config}->{seed_hub};
			if($seed_hub)
			{
				my @hubs;
				if($seed_hub =~ /,/)
				{
					@hubs = split /\s*,\s*/, $seed_hub;
				}
				else
				{
					@hubs = ( $seed_hub );
				}

				trace "MessageHub: \@hubs: (@hubs)\n";

				my %peers_by_host = map { $_->{host} => 1 } @list;
				@hubs = grep { $_ && !$peers_by_host{$_} } @hubs;

				#trace "MessageHub: \@hubs2: (@hubs)\n";
				
				#my @peers = map { HashNet::MP::PeerList->get_peer_by_host($_) } @hubs;
				foreach my $hub (@hubs)
				{
					# Provide a hashref to get_peer... so it automatically updates $peer if $host is not correct
					my $peer = HashNet::MP::PeerList->get_peer_by_host({host => $hub});
					push @list, $peer unless $peers_by_host{$hub};

					%peers_by_host = map { $_->{host} => 1 } @list;
				}

				#trace "MessageHub: \@peers: ".Dumper(\@peers);
				
				#push @list, @peers;
			}
		#}

		#trace "MessageHub: Final \@list: ".Dumper(\@list);
		
		foreach my $peer (@list)
		{
			next if !$peer || !$peer->{host};
			
			trace "MessageHub: Connecting to remote hub '$peer->{host}'\n";
			my $worker = $peer->open_connection($self->node_info);
			if(!$worker)
			{
				error "MessageHub: Error connecting to hub '$peer->{host}'\n";
			}
			else
			{
				trace "MessageHub: Connection established to hub '$peer->{host}'\n";
			}
		}
	}
	
	sub node_info
	{
		my $self = shift;

		return $self->{node_info} if $self->{node_info};
		return $self->{node_info} = {
			host => $self->{config}->{host} || undef,
			name => $self->{config}->{name},
			uuid => $self->{config}->{uuid},
			type => 'hub',
		}
	}
	
	sub start_server
	{
		my $self = shift;
		{package HashNet::MP::MessageHub::Server;
		
			use base qw(Net::Server::PreFork);
			use HashNet::Util::Logging;
			
			sub process_request
			{
				my $self = shift;
				
				$ENV{REMOTE_ADDR} = $self->{server}->{peeraddr};
				#print STDERR "MessageHub::Server: Connect from $ENV{REMOTE_ADDR}\n";
				
				#HashNet::MP::SocketWorker->new('-', 1); # '-' = stdin/out, 1 = no fork
				my $old_proc_name = $0;

				$0 = "$0 [Peer $ENV{REMOTE_ADDR}]";
				trace "MessageHub::Server: Client connected, forked PID $$ as '$0'\n";
				
				HashNet::MP::SocketWorker->new(
					sock		=> $self->{server}->{client},
					node_info	=> $self->{node_info},
					#use_globaldb	=> 1,
					no_fork		=> 1,
					# no_fork means that the new() method never returns here
				);

				$0 = $old_proc_name;
				
				#print STDERR "MessageHub::Server: Disconnect from $ENV{REMOTE_ADDR}\n";
			}
			
			# Hook from Net::Server, so we can mute the logging output with $HashNet::Util::Logging::LEVEL as needed/desired
			sub write_to_log_hook
			{
				my ($self, $level, $line) = @_;
				my @levels = qw/WARN INFO DEBUG TRACE/;
				HashNet::Util::Logging::logmsg($levels[$level], "MessageHub (Net::Server): ", $line, "\n");
			}
		};
	
		my $obj = HashNet::MP::MessageHub::Server->new(
			port => $self->{config}->{port},
			ipv  => '*'
		);
		
		$obj->{node_info} = $self->node_info;

		#use Data::Dumper;
		#print STDERR Dumper $obj;
		
		$obj->run();
		#exit();
	}

	sub start_router
	{
		my $self = shift;
		my $no_fork = shift || 0;
		if($no_fork)
		{
			$self->router_process_loop();
		}
		else
		{
			# Fork processing thread
			my $kid = fork();
			die "Fork failed" unless defined($kid);
			if ($kid == 0)
			{
				$0 = "$0 [Message Router]";
				
				info "Router PID $$ running as '$0'\n";
				RESTART_PROC_LOOP:
				eval
				{
					$self->router_process_loop();
				};
				if($@)
				{
					error "MessageHub: router_process_loop() crashed: $@";
					goto RESTART_PROC_LOOP;
				}
				info "Router PID $$ complete, exiting\n";
				exit 0;
			}

			# Parent continues here.
			while ((my $k = waitpid(-1, WNOHANG)) > 0)
			{
				# $k is kid pid, or -1 if no such, or 0 if some running none dead
				my $stat = $?;
				debug "Reaped $k stat $stat\n";
			}

			$self->{router_pid} = { pid => $kid, started_from => $$ };
		}
	}
	
	sub stop_router
	{
		my $self = shift;
		if($self->{router_pid} &&
		   $self->{router_pid}->{started_from} == $$)
		{
			trace "MessageHub: stop_router(): Killing router pid $self->{router_pid}->{pid}\n";
			kill 15, $self->{router_pid}->{pid};
		}
	}
	
	sub DESTROY
	{
		shift->stop_router();
	}
	
	sub router_process_loop
	{
		my $self = shift;

		my $self_uuid  = $self->node_info->{uuid};

		#trace "MessageHub: Starting router_process_loop()\n";
		
		while(1)
		{
			#my @list = $self->pending_messages;

			my @list;

			#$self->incoming_queue->lock_file;
			#exec_timeout( 3.0, sub { @list = pending_messages(incoming, nxthop => $self_uuid, no_del => 1) } );
			exec_timeout( 3.0, sub { @list = pending_messages(incoming, nxthop => $self_uuid ) } );
			
			#trace "MessageHub: router_process_loop: ".scalar(@list)." message to process\n";

			$self->outgoing_queue->pause_update_saves;
			
			foreach my $msg (@list)
			{
				if($msg->{type} eq MSG_CLIENT_RECEIPT)
				{
					# This is a receipt, saying the client picked up the message identified
					# by $msg->{data}->{msg_uuid}.
					# 
					# This receipt is useful to us because we want to remove any messages
					# stored for offline clients (offline to us) that received the message
					# we have stored by connecting to another hub
					# 
					# That way, when they connect back to us, they dont get deluged with a
					# backlog of messages that we have stored which they already received
					# elsewhere.
					#

					my $queue = outgoing_queue();
					my $rx_msg_uuid = $msg->{data}->{msg_uuid};
					my @queued = $queue->by_key(uuid => $rx_msg_uuid);
					@queued = grep { $_->{to} eq $msg->{from} } @queued;

					#trace "MessageHub: router_process_loop: Received MSG_CLIENT_RECEIPT for {$rx_msg_uuid}, receipt id {$msg->{uuid}}, lasthop $msg->{curhop}\n";

					#trace "MessageHub: Client Receipt Debug: ".Dumper(\@queued, $msg);

					$queue->del_batch(\@queued) if @queued;

				}

				my @recip_list;

				my @peers = HashNet::MP::PeerList->peers;
				#debug "MessageHub: remote_nodes: ".Dumper(\@remote_nodes);

				my $last_hop_uuid = $msg->{curhop};
				

				if($msg->{type} eq MSG_CLIENT_RECEIPT)
				{
					# If it's a broadcast client receipt, we grep out the last hop
					# so we dont just bounce it right back to the recipient
					@recip_list = grep { $_->uuid ne $last_hop_uuid } @peers;
				}
				elsif($msg->{bcast})
				{
					# If it's a broadcast message, we don't want to broadcast it back
					# to the last hop - but only if that last hop is a hub
					@recip_list = grep { $_->type eq 'hub' ? $_->uuid ne $last_hop_uuid : 1 } @peers;
					# list all known hubs, clients, etc
					#debug "MessageHub: bcast, peers: ".Dumper(\@peers);
				}
				else
				{
					my $to = $msg->{to};
					# if $to is a connect hub/peer, send directly to $to
					# Otherwise ...?
					#	- Query connect hubs?
					#	- Broadcast with a special flag to reply upon delivery...?
					my @find = grep { $_->uuid eq $to } @peers;
					if(@find == 1)
					{
						@recip_list = shift @find;
					}
					else
					{
						# TODO:
						# - Assume that when the final node gets the msg, it sends a non-sfwd reply back thru to the original sender
						# - As that non-sfwd reply goes thru hubs, each hub stores what the LAST hop was for that msg so it knows
						#   how best to get thru
						# - Then when we get to this case again (non-directly-connect peer),
						#   we grep our routing map for the hub from which we got a reply and try sending it there
						#	- That word 'try' implies we followup to make sure the msg was delivered......

						# Message not to a peer directly connected (e.g. to a client on another hub),
						# so until we develop a routing table mechanism, we just broadcast to all connected peers that are hubs
						@recip_list = grep { $_->type eq 'hub' } @peers;

						# If not store-forward, then we only want to send to peers currently online
						# since we dont want to store this message for any peers that are not currently
						# connect to this hub
					}
				}

				if(!$msg->{sfwd})
				{
					@recip_list = grep { $_->{online} } @recip_list;
				}

				debug "MessageHub: router_process_loop: Msg $msg->{type} UUID {$msg->{uuid}} for data '$msg->{data}': recip_list: {".join(' | ', map { $_->{name}.'{'.$_->{uuid}.'}' } @recip_list)."}\n"
					if @recip_list;
					
				#debug Dumper $msg, \@peers;

				foreach my $peer (@recip_list)
				{
					my @args =
					(
						$msg->{data},
						uuid	=> $msg->{uuid},
						hist	=> clean_ref($msg->{hist}),

						curhop	=> $self_uuid,
						nxthop	=> $peer->uuid,

						# Rewrwite the 'to' address if the msg is a broadcast msg AND the next hop is a 'client' because
						# clients just check the 'to' field to pickup messages
						# Clients do NOT check 'nxthop', just 'to' when picking up messages from the queue because
						# msgs could reach the client that are not broadcast and not to the client - they just
						# got sent to the client because the hub didn't know where the client was
						# connected - so we dont want the client to work with those messages.
						#to	=> $msg->{bcast} && $peer->{type} eq 'client' ? $peer->uuid : $msg->{to},
						to	=> $msg->{bcast} ? $peer->uuid : $msg->{to},
						from	=> $msg->{from},
					 
						bcast	=> $msg->{bcast},
						sfwd	=> $msg->{sfwd},
						type	=> $msg->{type},

						_att	=> $msg->{_att} || undef,
					);
					my $new_env = HashNet::MP::SocketWorker->create_envelope(@args);
					$self->outgoing_queue->add_row($new_env);
					#debug "MessageHub: router_process_loop: Msg UUID $msg->{uuid} for data '$msg->{data}': Next envelope: ".Dumper($new_env);
				}
			}

			#$self->incoming_queue->del_batch(\@list);
			#$self->incoming_queue->unlock_file;
			$self->outgoing_queue->resume_update_saves;

			sleep 0.25;
		}
		
	}
};
1;