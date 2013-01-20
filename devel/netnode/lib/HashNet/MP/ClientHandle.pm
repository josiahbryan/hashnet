{package HashNet::MP::ClientHandle;

	use common::sense;
	
	use HashNet::MP::PeerList;
	use HashNet::MP::MessageQueues;
	use HashNet::Util::Logging;
	use HashNet::Util::CleanRef;
	use Data::Dumper;
	use File::Basename; # for setup()

	sub MSG_CLIENT_RECEIPT { 'MSG_CLIENT_RECEIPT' }

	## Options:
	# (All options are optional, sensible defaults are provided for all values that will 'just work' in most cases)
	# - log_level   - Integer to set HashNet::Util::Logging::LEVEL, optional - if not given, ::LEVEL not set
	# - no_ansi     - Boolean, if true, HashNet::Util::Logging::ANSI_ENBALED is left at default, otherwise ANSI_ENABLED set to 1
	# - hosts       - Arrayref, list of hosts to try to connect in order, if not given, then @ARGV is used as list of hosts, unless:
	# - ignore_argv - Boolean, setup() will NOT use @ARGV as a list of hosts if 'hosts' option NOT provided if ignore_argv is true
	# - uuid        - UUID to use for this client in node_info arg to ClientHandle. If not provided, $0 is used
	# - name        - Name to use for this client in node_info arg to ClientHandle. If not provided, $0 is used
	# - use_default_db - Boolean, if true, $HashNet::MP::LocalDB::DBFILE is left at default value (e.g. not changed)
	# - db_prefix   - String, if use_default_db is false or not given, DBFILE is set to ".db." + db_prefix
	#                 If db_prefix not given, $0 is parsred and just the filename (sans extension and sans path) is used
		
	sub setup
	{
		shift if $_[0] eq __PACKAGE__;
		
		my %opts = @_;
		
		$HashNet::Util::Logging::LEVEL = $opts{log_level} if defined $opts{log_level};
		$HashNet::Util::Logging::ANSI_ENABLED = 1 unless $opts{no_ansi};
	
		my @hosts = @{ $opts{hosts} || ( $opts{ignore_argv} ? () : @ARGV ) };
	
		@hosts = ('localhost:8031') if !@hosts;
	
		my $node_info = {
			uuid => $opts{uuid} || $0,
			name => $opts{name} || $0,
			type => 'client',
		};
		
		if(!$opts{db_prefix})
		{
			my @parts = fileparse($0, qr/\.[^.]*/);
			$opts{db_prefix} = $parts[0];
		}
	
		#$HashNet::MP::LocalDB::DBFILE = "$0.$$.db";
		if(!$opts{use_default_db})
		{
			$HashNet::MP::LocalDB::DBFILE = ".db.".$opts{db_prefix};
			trace "ClientHandle: setup(): Using DBFILE '$HashNet::MP::LocalDB::DBFILE'\n";
		}
	
		my $eng = HashNet::MP::GlobalDB->new();
		
		my $ch;
		
		while(my $host = shift @hosts)
		{
			$ch = HashNet::MP::ClientHandle->connect($host, $node_info);
			if($ch)
			{
				$ENV{REMOTE_ADDR} = $host;
				info "ClientHandle: setup(): Connected to $ENV{REMOTE_ADDR}\n";
				last;
			}
		}
		
		if(!$ch)
		{
			die "Couldn't connect to any hosts (@hosts)";
		}
		
		$eng->set_client_handle($ch);
		$ch->{globaldb} = $eng;
		
		$ch->wait_for_start;
		
		return $ch;
	}
	
	sub destroy_app
	{
		my $ch = shift;
		
		$ch->wait_for_send;
		$ch->stop;

		HashNet::MP::LocalDB->dump_db($HashNet::MP::LocalDB::DBFILE);
		HashNet::MP::GlobalDB->delete_disk_cache($ch->globaldb->db_root);
	}
	
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

		my $self = bless {
			sw   => $worker,
			peer => $peer,
			send_receipts => 1,
			host => $host,
			node_info => $node_info,
		}, $class;

		#$self->start_watcher;

		return $self;
	};
	
	sub globaldb { shift->{globaldb} }

	sub sw			{
		my $self = shift;
		$self->reconnect_if_dead;
		return $self->{sw};
	}
	
	sub peer		{ shift->{peer} }

	sub send_ping		{ shift->sw->send_ping(@_) }
	
	sub wait_for_start	{ shift->sw->wait_for_start(@_)   }
	sub wait_for_send	{ shift->sw->wait_for_send(@_)    }
	sub wait_for_receive	{ shift->sw->wait_for_receive(@_) }
	sub stop		{
		my $self = shift;
		$self->sw->stop;
		$self->peer->close_tunnel(); # noop if no tunnel
	}

	sub uuid 		{ shift->sw->node_info->{uuid} }
	sub peer_uuid		{ shift->sw->state_handle->{remote_node_info}->{uuid} }
	
	sub DESTROY
	{
		my $self = shift;

		$self->stop;

# 		if($self->{watcher_pid} &&
# 		   $self->{watcher_pid}->{started_from} == $$)
# 		{
# 			kill 15, $self->{watcher_pid}->{pid};
# 		}
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

		# Check 'to' and not 'nxthop' because msgs could reach us
		# that are not broadcast and not to us - they just
		# got sent to our socket because the hub didn't know where the client was
		# connected - so we dont want the client to work with those messages
		my @msgs = pending_messages(incoming, to => $self->uuid, no_del => 1);

		if($self->{send_receipts})
		{
			# Return right away, send receipts from another fork
			#if(!fork)
			{
				my $sw = $self->sw;

				$self->outgoing_queue->begin_batch_update;

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

				#exit;
			}
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

# 	sub start_watcher
# 	{
# 		my $self = shift;
# 
# 		# Fork timer loop
# 		my $kid = fork();
# 		die "Fork failed" unless defined($kid);
# 		if ($kid == 0)
# 		{
# 			$0 = "$0 [ClientHandle Watcher]";
# 
# 			info "ClientHandle: Watcher PID $$ running as '$0'\n";
# 			RESTART_WATCHER_LOOP:
# 			eval
# 			{
# 				$self->watcher_loop();
# 			};
# 			if($@)
# 			{
# 				error "ClientHandle: watcher_loop() crashed: $@";
# 				goto RESTART_WATCHER_LOOP;
# 			}
# 			info "ClientHandle: Wathcer PID $$ complete, exiting\n";
# 			exit 0;
# 		}
# 
# 		# Parent continues here.
# 		while ((my $k = waitpid(-1, WNOHANG)) > 0)
# 		{
# 			# $k is kid pid, or -1 if no such, or 0 if some running none dead
# 			my $stat = $?;
# 			debug "Reaped $k stat $stat\n";
# 		}
# 
# 		$self->{watcher_pid} = { pid => $kid, started_from => $$ };
# 	}
# 
# 	sub watcher_loop
# 	{
# 		my $self = shift;
# 
# 		my $sw = $self->sw;
# 		while(1)
# 		{
# 			unless(kill 0, $sw->{child_pid})
# 			{
# 				error "ClientHandle: SocketWorker went away (was in PID $sw->{child_pid}), attempting reconnect\n";
# 			}
# 
# # 			my $env = $sw->create_envelope(MSG_KEEP_ALIVE, type => MSG_KEEP_ALIVE, sfwd => 0);
# # 			$sw->send_message($env);
# # 			
# # 
# # 			wait_for_receive(
# 		}
# 	}

	sub is_sw_dead
	{
		my $self = shift;
		return ! (kill 0, $self->{sw}->{rx_pid});
	}

	sub kill_sw
	{
		my $self = shift;
		# Kill both threads of the socketworker incase just the primary went away
		kill 15, $self->{sw}->{rx_pid} if $self->{sw}->{rx_pid};
		kill 15, $_ if $_ = $self->{sw}->state_handle->{tx_loop_pid};
		delete $self->{sw};
	}
	
	sub reconnect_if_dead
	{
		my $self = shift;
		my $timeout = shift || 10;
		my $speed = shift || 1;
		return 0 if !$self->is_sw_dead();
		$self->kill_sw();
		
		my $new_sw;
		trace "ClientHandle: Connection to host $self->{host} went away, trying to reconnect\n";
		my $time = time;
		while(time - $time < $timeout && !($new_sw = $self->peer->open_connection($self->{node_info})))
		{
			trace "ClientHandle: Reconnect to $self->{host} failed, sleeping 1 sec\n";
			sleep 1;
		}

		# TODO Is there a better way to handle this?
		die "ClientHandle: Connection to $self->{host} went away, unable to reconnect" if !$new_sw;
		
		$self->{sw} = $new_sw;
		trace "ClientHandle: Reconnected to $self->{host}\n";
		return 1;
		
	}
};
1;
