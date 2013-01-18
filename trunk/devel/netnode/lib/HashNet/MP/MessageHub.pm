{package HashNet::MP::MessageHub;
	
	use common::sense;

	use base qw/HashNet::MP::SocketTerminator/;

	use YAML::Tiny; # for load_config/save_config
	use UUID::Generator::PurePerl; # for node_info

	our $VERSION = 0.033;
	
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

	$SIG{CHLD} = 'IGNORE';

	our $CONFIG_FILE = [qw#hashnet-hub.conf /etc/hashnet-hub.conf#];
	our $DEFAULT_CONFIG =
	{
		port	 => 8031,
		#uuid	 => undef,
		#name	 => undef,
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
		
		# Load config options
		$self->read_config();
		
		# Start GlobalDB prior to connecting remote hubs
		# because the forks need the globaldb message handlers
		$self->start_globaldb();
		
		# Moved router ahead of connect_remote_hubs because
		# rewriting router to function as a custom message
		# handler plugin to SocketWorker
		$self->register_router();

		# Connect to remote hubs
		$self->connect_remote_hubs();

		# Start reconnect loop to watch for dead connections
		$self->start_reconnect_loop();
		
		# Start the router
		$self->start_router() if $opts{auto_start};

		# Start the server process
		$self->start_server() if $opts{auto_start};
	}
	
	sub start_globaldb
	{
		my $self = shift;
		# Start GlobalDB running and listening for incoming updates
		$self->{globaldb} = HashNet::MP::GlobalDB->new(
			hub_mode => 1,  # don't consume incoming messages
			rx_uuid  => $self->node_info->{uuid}, # need to know what UUID we're transmitting from since GlobalDB will never get a socketworker handle directly on a hub
		);
	}
	
	sub start_reconnect_loop
	{
		my $self = shift;
		
		# Fork reconnect loop
		my $kid = fork();
		die "Fork failed" unless defined($kid);
		if ($kid == 0)
		{
			my $orig_app = $0;
			$0 = "$0 [Reconnect Loop]";

			info "MessageHub: Reconnect Loop PID $$ running as '$0'\n";
			RESTART_reconnect_loop:
			eval
			{
				$self->reconnect_loop($orig_app);
			};
			if($@)
			{
				error "MessageHub: reconnect_loop() crashed: $@";
				goto RESTART_reconnect_loop;
			}
			info "Timer PID $$ complete, exiting\n";
			exit 0;
		}

		# Parent continues here.
		while ((my $k = waitpid(-1, WNOHANG)) > 0)
		{
			# $k is kid pid, or -1 if no such, or 0 if some running none dead
			my $stat = $?;
			debug "Reaped $k stat $stat\n";
		}

		$self->{timer_pid} = { pid => $kid, started_from => $$ };
	}
	
	sub set_repeat_timeout($$)
	{
		my ($time, $code_sub) = @_;
		my $timer_ref;
		my $wrapper_sub; $wrapper_sub = sub {
			
			$code_sub->();
			
			undef $timer_ref;
			# Yes, I know AE has an 'interval' property - but it does not seem to work,
			# or at least I couldn't get it working. This does work though.
			$timer_ref = AnyEvent->timer (after => $time, cb => $wrapper_sub);
		};
		
		# Initial call starts the timer
		#$wrapper_sub->();
		
		# Sometimes doesn't work...
		$timer_ref = AnyEvent->timer (after => $time, cb => $wrapper_sub);
		
		return $code_sub;
	};
	
	sub set_timeout($$)
	{
		my ($time, $code_sub) = @_;
		my $timer_ref;
		my $wrapper_sub; $wrapper_sub = sub {
			
			$code_sub->();
			
			undef $timer_ref;
			undef $wrapper_sub;
		};
		
		$timer_ref = AnyEvent->timer (after => $time, cb => $wrapper_sub);
		
		return $code_sub;
	}
	
	sub reconnect_loop
	{
		my $self = shift;
		my $orig_app = shift;

		sleep 3;

		logmsg "TRACE", "MessageHub: Starting reconnect loop...\n";

		while(1)
		{
			#trace "MessageHub: reconnect_loop(): building hub list...\n";
			my @list = $self->build_hub_list();
			#trace "MessageHub: reconnect_loop(): have ".scalar(@list)." hubs to check...\n";

			#trace "MessageHub: Final \@list: ".Dumper(\@list);

			foreach my $peer (@list)
			{
				#trace "MessageHub: Reconnect Check: Checking hub '$peer->{host}'...\n";
				next if !$peer || !$peer->host;
				next if $peer->is_online;
				#next if $peer->is_connecting;
				if($peer->is_connecting)
				{
					#trace "MessageHub: Reconnect Check: Hub '$peer->{host}' is not online, but it is connecting, skipping for now\n";
					next;
				}

				my $time = time - $peer->{last_reconnect_time};
				if($time < 30)
				{
					trace "MessageHub: Reconnect Check: Hub '$peer->{host}' is not online, not connecting, but within the 30sec window ($time sec), waiting to see if state changes to connecting\n";
					next;
				}

				$peer->{last_reconnect_time} = time;
				HashNet::MP::PeerList->update_peer($peer);

				if(!fork)
				{
					$0 = "$orig_app [Reconnect: $peer->{host}]";
					trace "MessageHub: Reconnect Check: Attempting to reconnect to remote hub '$peer->{host}'\n";
					my $worker = $peer->open_connection($self->node_info);
					if(!$worker)
					{
						error "MessageHub: Reconnect Check: Error reconnecting to hub '$peer->{host}'\n";
					}
					else
					{
						trace "MessageHub: Reconnect Check: Connection reestablished to hub '$peer->{host}'\n";
					}
					exit;
				}
			}

			sleep 5;
		};
	}

	
	sub check_config_items
	{
		my $self = shift;

		$self->{config} = {} if !$self->{config};
		my $cfg = shift || $self->{config};

		foreach my $key (keys %{$self->{opts} || {}})
		{
			my $val = $self->{opts}->{$key};
			trace "MessageHub: Config option overwritten by script code: '$key' => '$val'\n";
			$cfg->{$key} = $val;
		}

		foreach my $key (keys %$DEFAULT_CONFIG)
		{
			$cfg->{$key} = $DEFAULT_CONFIG->{$key} if ! $cfg->{$key};
		}
		
		mkpath($cfg->{data_dir}) if !-d $cfg->{data_dir};

		$self->save_config;

		#trace "MessageHub: Config dump: ".Dumper($cfg);
	}
	
	sub build_hub_list
	{
		my $self = shift;
		my @list = HashNet::MP::PeerList->peers_by_type('hub');
		
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

			#trace "MessageHub: \@hubs: (@hubs)\n";

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

		my %peers_by_host = ();
		my @tmp;
		foreach my $peer (@list)
		{
			if(!$peers_by_host{$peer->{host}})
			{
				$peers_by_host{$peer->{host}} = 1;
				push @tmp, $peer;
			}
		}
		@list = @tmp;
		
		
		return @list;
	}
	
	sub connect_remote_hubs
	{
		my $self = shift;
		
		my @list = $self->build_hub_list();
	
		#trace "MessageHub: Final \@list: ".Dumper(\@list);
		
		foreach my $peer (@list)
		{
			next if !$peer || !$peer->host;
			if(!fork)
			{
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
				
				exit;
			}
		}
	}

	sub select_config_file
	{
		my $self = shift;
		my $config_file = shift;
		
		$config_file = $self->{opts}->{config_file} if ref $self && !$config_file;
		$config_file = $CONFIG_FILE if !$config_file;
		
		if(ref($config_file) eq 'ARRAY')
		{
			my @files = @$config_file;
			my $found = 0;
			foreach my $file (@files)
			{
				if(-f $file)
				{
					#logmsg "DEBUG", "PeerServer: Using config file '$file'\n";
					$config_file = $file;
					$found = 1;
					last;
				}
			}

			if(!$found)
			{
				my $file = shift @$config_file;
				logmsg "WARN", "MessageHub: No config file found, using default location '$file'\n";
				$config_file = $file;
			}
		}
		else
		{
			#die Dumper $CONFIG_FILE;
		}
		
		return $config_file;
	}

	sub read_config
	{
		my $self = shift;

		my $config_file = $self->select_config_file();
		
		$self->{config_file} = $config_file;

		#logmsg "DEBUG", "PeerServer: Loading config from $CONFIG_FILE\n";
		my $config = {};
		$config = YAML::Tiny::LoadFile($config_file) if -f $config_file;
		
		# Offline mode, just return check and return hashref
		if(!ref $self)
		{
			# Do what check_node_info does, just dont save
			my $inf = $config->{node_info};
			HashNet::MP::SocketWorker->update_node_info($inf);
			$inf->{hub_ver} = $VERSION;
			$inf->{type}    = 'hub';
			
			# Do part of what check_config_items does
			my $cfg = $config->{config};
			foreach my $key (keys %$DEFAULT_CONFIG)
			{
				$cfg->{$key} = $DEFAULT_CONFIG->{$key} if ! $cfg->{$key};
			}
			
			return $config;
		}
		
		#print Dumper $config;
		$self->{node_info} = $config->{node_info};
		#delete $config->{node_info};
		
		$self->{config}    = $config->{config};
		
		$self->check_node_info();
		$self->check_config_items();
	}

	sub save_config
	{
		my $self = shift;
		my $config =
		{
			node_info => $self->{node_info},
			config    => $self->{config},
		};
		#trace Dumper($self);
		
		logmsg "DEBUG", "PeerServer: Saving config to $self->{config_file}\n";
		YAML::Tiny::DumpFile($self->{config_file}, $config);

		return if ! $self->{node_info_changed_flag_file};

		# The reconnect loop will check for the existance of this file and push the node info into the storage engine
		#open(FILE,">$self->{node_info_changed_flag_file}") || warn "Unable to write to $self->{node_info_changed_flag_file}: $!";
		#print FILE "1\n";
		#close(FILE);
	}
	
	sub node_info
	{
		my $self = shift;
		my $force_check = shift || 0;

# 		return $self->{node_info} if $self->{node_info};
# 		return $self->{node_info} = {
# 			host => $self->{config}->{host} || undef,
# 			name => $self->{config}->{name},
# 			uuid => $self->{config}->{uuid},
# 			type => 'hub',
# 		}

		$self->check_node_info($force_check);

		return $self->{node_info};
	}

	sub check_node_info
	{
		my $self = shift;
		my $force = shift || 0;

		return if !$force && $self->{_node_info_audited};
		$self->{_node_info_audited} = 1;


		# Fields:
		# - Host Name
		# - WAN IP
		# - Geo locate
		# - LAN IPs
		# - MAC(s)?
		# - Host UUID
		# - OS Info

		$self->{node_info} ||= {};

		#logmsg "TRACE", "PeerServer: Auditing node_info() for name, UUID, and IP info\n";


		my $changed = 0;
		my $inf = $self->{node_info};

		$changed = HashNet::MP::SocketWorker->update_node_info($inf);

		$inf->{hub_ver} = $VERSION;
		$inf->{type}    = 'hub';

		$self->save_config if $changed;
		#logmsg "INFO", "PeerServer: Node info audit done.\n";
	}

	
	sub start_server
	{
		my $self = shift;
		{package HashNet::MP::MessageHub::Server;
		
			#use base qw(Net::Server::PreFork);
			use base qw(Net::Server::Fork);
			use HashNet::Util::Logging;
			
			sub process_request
			{
				my $self = shift;
				
				$ENV{REMOTE_ADDR} = $self->{server}->{peeraddr};
				#print STDERR "MessageHub::Server: Connect from $ENV{REMOTE_ADDR}\n";
				
				#HashNet::MP::SocketWorker->new('-', 1); # '-' = stdin/out, 1 = no fork
				my $old_proc_name = $0;

				$0 = "$0 [$ENV{REMOTE_ADDR}]";
				trace "MessageHub::Server: Client connected, forked PID $$ as '$0'\n";
				
				HashNet::MP::SocketWorker->new(
					sock		=> $self->{server}->{client},
					node_info	=> $self->{node_info},
					hub_mode	=> 1,
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

				info "MessageHub: Router PID $$ running as '$0'\n";
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
				info "MessageHub: Router PID $$ complete, exiting\n";
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
	
	sub stop_reconnect_loop
	{
		my $self = shift;
		if($self->{timer_pid} &&
		   $self->{timer_pid}->{pid} && 
		   $self->{timer_pid}->{started_from} == $$)
		{
			trace "MessageHub: stop_reconnect_loop(): Killing reconnect loop pid $self->{timer_pid}->{pid}\n";
			kill 15, $self->{timer_pid}->{pid};
		}
	}
	
	sub DESTROY
	{
		my $self = shift;
		$self->stop_router();
		$self->stop_reconnect_loop();
	}
	
	sub route_table
	{
		my $self = shift;
		return $self->{route_table} if defined $self->{route_table};
		my $ref = HashNet::MP::LocalDB->indexed_handle('/hub/routing');
		$self->{route_table} = $ref;
		return $ref;
	}
	
	sub router_process_loop
	{
		my $self = shift;

		#trace "MessageHub: Starting router_process_loop()\n";
		my $self_uuid  = $self->node_info->{uuid};

		while(1)
		{
			#my @list = $self->pending_messages;

			my @list;

			$self->incoming_queue->lock_file;
			exec_timeout( 3.0, sub { @list = pending_messages(incoming, nxthop => $self_uuid, no_del => 1) } );
			#exec_timeout( 3.0, sub { @list = pending_messages(incoming, nxthop => $self_uuid ) } );

			#trace "MessageHub: router_process_loop: ".scalar(@list)." message to process\n";

			if(@list)
			{
				if($self->outgoing_queue->begin_batch_update)
				{
					my @del_batch;
					foreach my $msg (@list)
					{
						local *@;
						eval { push @del_batch, $msg if $self->route_message($msg); };
						trace "MessageHub: Error in route_message(): $@" if $@;
					}

					$self->incoming_queue->del_batch(\@del_batch);
					$self->incoming_queue->unlock_file;
					
					$self->outgoing_queue->end_batch_update;
				}
				else
				{
					trace "MessageHub: router_process_loop: Error locking file in begin_batch_update()\n";
				}
			}

			sleep 1.0;
		}
	}

	sub register_router
	{
		my $self = shift;

		# Handlers registered prior to a SocketWorker being created are called
		# from within the SocketWorker's thread (fork), so operations here
		# must be done with that in mind. E.g. shared variables that are to be
		# used outside of route_message() or across other calls must be
		# be variables that can communicate IPC, e.g. SharedRef or the like.
		HashNet::MP::SocketWorker->reg_msg_handler('*' => sub
		{
			my ($msg) = @_;

			my $type = $msg->{type};

			#trace "MessageHub: catch all handler: Received message ${type}{$msg->{uuid}}\n";
			
			return 0 if $type eq 'MSG_NODE_INFO';

			# If route_message failes to lock outgoing queue, it
			# will return 0, allowing the msg to fall into the
			# incoming_queue, which will then be picked up by the router_process_loop
			return 1 if $self->route_message($msg);

			return 0;
		});
	}
	
	sub check_route_hist
	{
		my $hist = shift;
		my $to = shift;
		return if !ref $hist;

		my @hist = @{$hist || []};
		foreach my $line (@hist)
		{
			return 1 if $line->{to} eq $to;
		}
		return 0;
	}

	sub update_routing_table
	{
		my $self = shift;
		my $msg = shift;
		if($msg->{hist})
		{
			#trace "MessageHub: update_routing_table: Processing history route for msg for {$msg->{uuid}}, lasthop $msg->{curhop}\n";

			my @hist = @{$msg->{hist} || []};
			my %ident;
			my $ident = 0;
			my %nodes;
			$nodes{$self->node_info->{uuid}} = $self->node_info;

			#trace "MessageHub: update_routing_table: Received MSG_CLIENT_RECEIPT for msg {$rx_msg_uuid}, receipt id {$msg->{uuid}}\n"; #, lasthop $msg->{curhop}\n";
			$hist[$#hist]->{last} = 1 if @hist;
			my $last_to = undef;
			my $last_time = time();
			foreach my $item (@hist)
			{
				#next if defined $last_to && !$item->{last} && $item->{from} ne $last_to;

				my $time  = $item->{time};
				my $uuid  = $item->{to};
				my $uuid2 = $item->{from};
				my $delta = $time - $last_time;
				my $info  = $nodes{$uuid};

				#next if !$info;
				my $key = $uuid2; #.$uuid;
				my $ident = $ident{$key} || ++ $ident;
				$ident{$key} = $ident;
				my $prefix = "\t" x $ident;

				#trace "$prefix -> " . ($nodes{$uuid2} ? $nodes{$uuid2}->{name} : $uuid2) . " -> " . ($info ? $info->{name} : $uuid)." (".sprintf('%.03f', $delta)."s)\n";

				$last_to = $uuid;
				$last_time = $time;
			}

			if(@hist)
			{
				my $route_to = $hist[0]->{from};
				my $route_from = $hist[$#hist]->{from}; # not 'to', because last @hist is 'to' this node
				my $tbl = $self->route_table;
				
				# TODO: Handle failure to lock in begin_batch_update() 
				$tbl->begin_batch_update;
				eval
				{
					my $route_row = $tbl->by_key('dest' => $route_to);
					if(!$route_row)
					{
						if(@hist > 1)
						{
							$route_row = { dest => $route_to, nxthop => $route_from };
							$tbl->add_row($route_row);

							$self->reroute_queued_messages($route_row);

							#trace "MessageHub: update_routing_table: [Route Table Update]: Added new route for '$route_to' to nxthop '$route_from'\n";
						}

					}
					elsif(@hist == 1)#$route_to eq $route_from)
					{
						# If only one row in hist, then it follows that
						# the sender of this receipt is directly connected
						# to this hub.
						# Since it's directly connected to this hub,
						# the route table does NOT need an entry,
						# since the peer will be listed in the PeerList
						# and if its online, then it will be found that way.
						# If the peer is offline, even if in the PeerList,
						# *then* the route table will be consulted.
						# Hopefully by then, the peer desired will have
						# sent out a receipt that we've picked up here.
						# Anyway, if directly connected, just remove
						# $route_row
						if($route_row)
						{
							$tbl->del_row($route_row);
							#trace "MessageHub: update_routing_table: [Route Table Update]: Removed route for '$route_to' since it's directly connected now\n";
						}
					}
					else
					{
						if($route_from ne $route_row->{nxthop})
						{
							$route_row->{nxthop} = $route_from;
							$route_row->{count}  = 0;

							$self->reroute_queued_messages($route_row);
							#trace "MessageHub: update_routing_table: [Route Table Update]: Updated route for '$route_to' to nxthop '$route_from'\n";
						}
						else
						{
							#trace "MessageHub: update_routing_table: [Route Table Update]: Route for '$route_to' / nxthop '$route_from' is current, no update needed\n";
						}

						$route_row->{timestamp} = time();
						$route_row->{count} ++;
						$tbl->update_row($route_row);
					}
				};
				if($@)
				{
					error "MessageHub: update_routing_table: Error updating route table: $@\n";
					warn "Error updating route table: $@";
				}
				$tbl->end_batch_update;
			}

			# TODO: Should we consider rewriting any envelopes in the outgoing queue that are for $route_to, with nxthop as $route_to, to have a nxthop of $route_from, if @hist > 1?
			# TODO: What happens if the route is stale?
			# 	-eg:
			#	- Server A, Server B, and Client 1
			#	- C1 connects to SA, then disconnects
			#	- C1 connects to SB, sends receipt, SA picks up and routes msgs for C1 to SB
			#	- C1 disconnects from SB
			#	- Cx sends msg to C1 via SA
			#	- SA routes to SB (last known)
			#	- SB:
			#		- Peer offline, so it doesnt go right to the peer
			#		- Route table empty for C1 (since it was direct connect)
			#		- Broadcast to all hubs, in this case SA
			#		- SA:
			#			- SA rejects msg because history shows it came thru here
		}
	}

	sub process_client_receipt
	{
		my $self = shift;
		my $msg = shift;
		
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

		# TODO Rewrite for custom SW outgoing queue
		my $queue = outgoing_queue();
		my $rx_msg_uuid = $msg->{data}->{msg_uuid};

		#$queue->begin_batch_update; # also locks the file
		#$queue->lock_file;
		eval {
			my @queued = $queue->by_key(uuid => $rx_msg_uuid);

			# Dont delete broadcast messages with same uuid
			@queued = grep { $_->{to} eq $msg->{from} } @queued;

			#trace "MessageHub: process_client_receipt: Received MSG_CLIENT_RECEIPT for {$rx_msg_uuid}, receipt id {$msg->{uuid}}, lasthop $msg->{curhop}\n";

			#trace "MessageHub: Client Receipt Debug: ".Dumper(\@queued, $msg);

			$queue->del_batch(\@queued) if @queued;
		};
		#$queue->unlock_file;
		#$queue->end_batch_update; # also unlocks the file
	}

	sub reroute_queued_messages#($route_row)
	{
		my $self = shift;
		my $route = shift;

		# TODO Rewrite for custom SW outgoing queue
		my $queue  = outgoing_queue();
		my $dest   = $route->{dest};
		my $nxthop = $route->{nxthop};
		my @queued = $queue->by_key( to => $dest );

		$queue->begin_batch_update;
		local *@;
		eval
		{
			foreach my $msg (@queued)
			{
				if($msg->{nxthop} ne $nxthop &&
				   $msg->{nxthop} ne $dest)
				{
					$msg->{nxthop} = $nxthop;
					$queue->update_row($msg);
				}
			}
		};
		error "MessageHub: reroute_queued_messages: Error rerouting: $@" if $@;
		$queue->end_batch_update;
	}


	sub route_message
	{
		my $self = shift;
		my $msg = shift;
		my $self_uuid  = $self->node_info->{uuid};
		
		#debug "--------------------------------------------------------\n";
		#debug "MessageHub: route_message: Msg $msg->{type} UUID {$msg->{uuid}} for data '$msg->{data}': Starting processing\n";
		
		$self->update_routing_table($msg);
		
		$self->process_client_receipt($msg)
			if $msg->{type} eq MSG_CLIENT_RECEIPT;

		my @recip_list;

		my @peers = HashNet::MP::PeerList->peers;
		#debug "MessageHub: remote_nodes: ".Dumper(\@remote_nodes);

		my $last_hop_uuid = $msg->{curhop};

		if($msg->{type} eq MSG_CLIENT_RECEIPT)
		{
			# If it's a broadcast client receipt, we grep out the last hop
			# so we dont just bounce it right back to the recipient
			my %hist = map { $_->{from} => 1 } @{$msg->{hist} || []};
			#@recip_list = grep { $_->uuid ne $last_hop_uuid } @peers;
			@recip_list = grep { !$hist{ $_->uuid } } @peers;
		}
		elsif($msg->{bcast})
		{
			# If it's a broadcast message, we don't want to broadcast it back
			# to the last hop - but only if that last hop is a hub
			my %hist = map { $_->{from} => 1 } @{$msg->{hist} || []};
			#@recip_list = grep { $_->type eq 'hub' ? $_->uuid ne $last_hop_uuid : 1 } @peers;
			@recip_list = grep { $_->type eq 'hub' ? !$hist{ $_->uuid } : 1 } @peers;
			# list all known hubs, clients, etc
			#debug "MessageHub: bcast, peers: ".Dumper(\@peers);
		}
		elsif($msg->{to} eq $self_uuid)
		{
			my $peer = HashNet::MP::PeerList->get_peer_by_uuid($msg->{curhop});
			my $cname = $peer ? $peer->{name} : '?';
			debug "MessageHub: route_message: [evaporating] ".$msg->{type}."{$msg->{uuid}}: '$msg->{data}' (lasthop: ${cname}{$msg->{curhop}}  destined for this hub, evaporating\n";
		}
		else
		{
			my $to = $msg->{to};
			# if $to is a connect hub/peer, send directly to $to
			# Otherwise ...?
			#	- Query connect hubs?
			#	- Broadcast with a special flag to reply upon delivery...?
			my @find = grep { $_->uuid eq $to } @peers;
			
			# We want to know if it was a direct connect even if its not online for the sake of routing, below
			my $is_direct_connect = @find == 1 ? $find[0] : 0;
			
			#trace "MessageHub: route_message: [DC debug] \$is_direct_connect:'$is_direct_connect', to: '$to', \@find: ".Dumper(\@find), ", \@peers: ".Dumper(\@peers); 
			@find = () if @find == 1 && !$find[0]->is_online; 
			
			if(@find == 1)
			{
				@recip_list = shift @find;
				#trace "MessageHub: route_message: I think '$to' is this peer: ".Dumper(\@recip_list);
			}
			else
			{
				my $route_to = $to;
				my $tbl   = $self->route_table;
				my $route = $tbl->by_key('dest' => $route_to);
				my ($uuid, $peer);
				if(!$route)
				{
					if($is_direct_connect)
					{
						trace "MessageHub: route_message: [route tbl check] No other route exists offline DC '$route_to', routing to local queue\n";
						$peer = $is_direct_connect;
					}
					else
					{
						trace "MessageHub: route_message: [route tbl check] No route exists for '$route_to'\n";
					}
				}
				else
				{
					$uuid = $route->{nxthop};
					$peer = HashNet::MP::PeerList->get_peer_by_uuid($uuid);
					if(!$peer)
					{
						trace "MessageHub: route_message: [route tbl check] Found nxthop '$uuid' for '$route_to', but no entry in PeerList for that nxthop!\n";
					}
				}
				
				if($peer)
				{
					@recip_list = ($peer);
					#trace "MessageHub: route_message: [route tbl check] Found route to '$route_to', recip_list now: ".Dumper(\@recip_list);
				}
				else
				{
					# No route existed for the destination, so broadcast it to all hubs to allow them to check their routes and direct-connect clients
					@recip_list = grep { $_->type eq 'hub' } @peers;
					
					# Also add a recip entry for the dest itself because it's possible that destination uuid ($to)
					# has not come online ANYWHERE on the network. If we did not do this (add $to to the recip list),
					# then the message would be broadcast to all peers, all peers would have no idea where to find
					# $to, and they would re-broadcast it - and since SocketWorker rejects incoming messages
					# that have been here before, when the other peers broadcast back to this one,
					# the message would get dropped - basically, the message would evaporate.
					# This line here (adding $to to @recip_list) protects against that message evaporation by 
					# putting the message in our outgoing queue directly to $to incase $to happens to connect
					# to this hub. If $to connects to another hub and picks up the message there, a MSG_CLIENT_RECEIPT
					# (should) get broadcast, and we'll pick that up (above), and erase the message from our
					# outgoing queue so it doesnt just take up space. 
					push @recip_list, HashNet::MP::PeerList->get_peer_by_uuid($to);
	
					trace "MessageHub: route_message: Didn't know where '$to' was, so sending to all these places: ".Dumper(\@recip_list);
				}
			}
		}

		# If not store-forward, then we only want to send to peers currently online
		# since we dont want to store this message for any peers that are not currently
		# connect to this hub
		if(!$msg->{sfwd})
		{
			@recip_list = grep { $_->{online} } @recip_list;
		}

		debug "MessageHub: route_message: Msg $msg->{type} UUID {$msg->{uuid}} for data '$msg->{data}': recip_list: {".join(' | ', map { $_->{name}.'{'.$_->{uuid}.'}' } @recip_list)."}\n"
		;#	if @recip_list;

		#debug Dumper $msg, \@peers;

		if($self->outgoing_queue->begin_batch_update)
		{
		
			foreach my $peer (@recip_list)
			{
				next if !defined $peer->uuid;

				my $dest_uuid = $msg->{bcast} ? $peer->uuid : $msg->{to};
	# 			if(check_route_hist($msg->{hist}, $dest_uuid))
	# 			{
	# 				info "MessageHub: route_message: NOT creating envelope to $dest_uuid, history says it was already sent there.\n"; #: ".Dumper($envelope);
	# 				next;
	# 			}

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
					to	=> $dest_uuid,
					from	=> $msg->{from},

					bcast	=> $msg->{bcast},
					sfwd	=> $msg->{sfwd},
					type	=> $msg->{type},

					_att	=> $msg->{_att} || undef,
				);

				my $new_env = HashNet::MP::SocketWorker->create_envelope(@args);

				# TODO Rewrite for custom SW outgoing queue
				$self->outgoing_queue->add_row($new_env);
				#debug "MessageHub: route_message: Msg $msg->{type} UUID {$msg->{uuid}} for data '$msg->{data}': Next envelope: ".Dumper($new_env);
			}

			$self->outgoing_queue->end_batch_update;

			return 1;
		}
		else
		{
			info "MessageHub: route_message: Failed to lock outgoing_queue, failling thru\n";
			return 0;
		}
	}
};
1;
