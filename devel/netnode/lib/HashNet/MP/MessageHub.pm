{package HashNet::MP::MessageHub;
	
	use common::sense;

	use base qw/HashNet::MP::SocketTerminator/;
	
	use HashNet::MP::SocketWorker;
	use HashNet::MP::LocalDB;
	use HashNet::MP::PeerList;
	use HashNet::Util::Logging;
	use HashNet::Util::CleanRef;

	use POSIX;

	use Time::HiRes qw/alarm sleep/;

	use Data::Dumper;
	
	use File::Path qw/mkpath/;

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
		
		my $self = bless \%opts, $class;
		
		$self->read_config();
		$self->connect_remote_hubs();
		$self->start_router() if $opts{auto_start};
		$self->start_server() if $opts{auto_start};
	}
	
	sub read_config
	{
		my $self = shift;
		my $config = $self->{config} || $DEFAULT_CONFIG_FILE;
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
				$DEFAULT_CONFIG->{name} = `hostname -s`;
				$DEFAULT_CONFIG->{name} =~ s/[\r\n]//g;
	
				$DEFAULT_CONFIG->{uuid} = `uuidgen`;
				$DEFAULT_CONFIG->{uuid} =~ s/[\r\n]//g;
				
				$DEFAULT_CONFIG->{data_dir} = $self->{data_dir} if $self->{data_dir};
				
				warn "MessageHub: read_config: Unable to find config, using default settings: ".Dumper($DEFAULT_CONFIG);
				$self->{config} = $DEFAULT_CONFIG;
				
				$self->write_default_config();
				
				$self->check_config_items();
				return;
				
			}
		}
		
		open(FILE, "<$config") || die "MessageHub: Cannot read config '$config': $!";
		
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
		
		$self->check_config_items();
	}
	
	sub write_default_config
	{
		my $self = shift;
		my $cfg = $self->{config};
		my $file = ref $DEFAULT_CONFIG_FILE eq 'ARRAY' ? $DEFAULT_CONFIG_FILE->[0] : $DEFAULT_CONFIG_FILE;
		open(FILE, ">$file") || die "MessageHub: write_default_config: Cannot write to $file: $!";
		print FILE "$_: $cfg->{$_}\n" foreach keys %{$cfg || {}};
		close(FILE);
		warn "MessageHub: Wrote default configuration settings to $file\n";
	}
	
	sub check_config_items
	{
		my $self = shift;
		my $cfg = shift;
		
		mkpath($cfg->{data_dir}) if !-d $cfg->{data_dir};
	}
	
	sub _dbh
	{
		my $self = shift;
		my $file = $self->{config}->{data_dir} . '/hub.db';
		return HashNet::MP::LocalDB->handle($file);
	}
	
	sub connect_remote_hubs
	{
		my $self = shift;
		my $dbh = $self->_dbh;
		my $list = $dbh->{remote_hubs};
		
		if(!$list || !@{$list || []})
		{
			my $seed_hub = $self->{config}->{seed_hubs};
			if($seed_hub)
			{

				my @hubs;
				if($seed_hub =~ /,/)
				{
					@hubs = map { { 'host' => $_ }  } split /\s*,\s*/, $seed_hub;
				}
				else
				{
					@hubs = ({ host => $seed_hub });
				}

				$list =
					$dbh->{remote_hubs} = \@hubs;
			}
		}
		
		foreach my $data (@$list)
		{
			#my $sock = $self->_get_socket($data->{host});
			my $peer = HashNet::MP::PeerList->get_peer_by_host($data->{host});
			if($peer)
			{
				my $worker = $peer->open_connection($self);
			}

		}
	}
	
	sub node_info
	{
		my $self = shift;

		return $self->{node_info} if $self->{node_info};
		return $self->{node_info} = {
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
			
			sub process_request
			{
				my $self = shift;
				
				$ENV{REMOTE_ADDR} = $self->{server}->{peeraddr};
				#print STDERR "MessageHub::Server: Connect from $ENV{REMOTE_ADDR}\n";
				
				#HashNet::MP::SocketWorker->new('-', 1); # '-' = stdin/out, 1 = no fork
				
				HashNet::MP::SocketWorker->new(
					sock		=> $self->{server}->{client},
					node_info	=> $self->{node_info},
					term		=> $self->{term},
					no_fork		=> 1,
				);
				
				#print STDERR "MessageHub::Server: Disconnect from $ENV{REMOTE_ADDR}\n";
			}
		};
	
		my $obj = HashNet::MP::MessageHub::Server->new(
			port => $self->{config}->{port},
			ipv => '*'
		);
		
		$obj->{node_info} = $self->node_info,
		$obj->{term}      = $self;
		$obj->run();
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
				info "Router PID $$ running\n";
				$self->router_process_loop();
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

			$self->{router_pid} = $kid;
		}
	}
	
	sub stop_router
	{
		my $self = shift;
		if($self->{router_pid})
		{
			kill 15, $self->{router_pid};
		}
	}

	sub msg_queue
	{
		my $self = shift;
		my $queue = shift;

		return  $self->{queues}->{$queue}->{ref} if
			$self->{queues}->{$queue}->{pid} == $$;

		#trace "SocketWorker: msg_queue($queue): (re)creating queue in pid $$\n";
		my $ref = HashNet::MP::LocalDB->indexed_handle('/queues/'.$queue);
		$self->{queues}->{$queue} = { ref => $ref, pid => $$ };
		return $ref;
	}

	sub incoming_queue { shift->msg_queue('incoming') }
	sub outgoing_queue { shift->msg_queue('outgoing') }

	use Data::Dumper;
	sub pending_messages
	{
		my $self = shift;
		#return () if !$self->peer;

		my $uuid  = $self->node_info->{uuid};
		my $queue = $self->incoming_queue;
		my @list  = $queue->by_field(nxthop => $uuid);
		@list = sort { $a->{time} cmp $b->{time} } @list;

		#trace "MessageHub: pending_messages: Found ".scalar(@list)." messages for peer {$uuid}\n" if @list;
		#print STDERR Dumper(\@list) if @list;
		#print STDERR Dumper($self->peer);

		my @return_list = map { clean_ref($_) } grep { defined $_ } @list;

		$queue->del_batch(\@list);
		#print STDERR Dumper(\@return_list) if @return_list;
		return @return_list;
	}


	sub router_process_loop
	{
		my $self = shift;

		my $self_uuid  = $self->node_info->{uuid};
		
		while(1)
		{
			my @list = $self->pending_messages;
			foreach my $msg (@list)
			{
				my @recip_list;

				#my @app_local_states = HashNet::MP::SocketWorker->app_local_states;
				#debug "MessageHub: app_local_states: ".Dumper(\@app_local_states);
				
				#my @remote_nodes = map { $_->{remote_node_info}->{uuid} } @app_local_states;
				#debug "MessageHub: remote_nodes: ".Dumper(\@remote_nodes);

				my @peers = HashNet::MP::PeerList->peers;
				my @remote_nodes = map { $_->{uuid} } @peers;
				#debug "MessageHub: remote_nodes: ".Dumper(\@remote_nodes);
				
				if($msg->{bcast})
				{
					@recip_list = @remote_nodes;
					# list all known hubs, peers, etc
				}
				else
				{
					my $to = $msg->{to};
					# if $to is a connect hub/peer, send directly to $to
					# Otherwise ...?
					#	- Query connect hubs?
					#	- Broadcast with a special flag to reply upon delivery...?
					my @find = grep { $_ eq $to } @remote_nodes;
					if(@find == 1)
					{
						@recip_list = $to;
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
						@recip_list = @remote_nodes;
					}
				}
				debug "MessageHub: router_process_loop: Msg UUID $msg->{uuid} for data '$msg->{data}': recip_list: {".join(' | ', @recip_list)."}\n";

				foreach my $recip (@recip_list)
				{
					my @args =
					(
						$msg->{data},
						uuid	=> $msg->{uuid},
						hist	=> $msg->{hist},
						curhop	=> $self_uuid,
						nxthop	=> $recip,
						from	=> $msg->{from},
						to	=> $msg->{to},
						bcast	=> $msg->{bcast},
						sfwd	=> $msg->{sfwd},
						type	=> $msg->{type},
					);
					my $new_env = HashNet::MP::SocketWorker->create_envelope(@args);
					$self->outgoing_queue->add_row($new_env);
					#debug "MessageHub: router_process_loop: Msg UUID $msg->{uuid} for data '$msg->{data}': Next envelope: ".Dumper($new_env);
				}
					
			}

			sleep 0.2;
		}
		
	}
};
1;