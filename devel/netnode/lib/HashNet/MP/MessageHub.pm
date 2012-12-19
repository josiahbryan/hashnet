{package HashNet::MP::MessageHub;
	
	use common::sense;

	use base qw/HashNet::MP::SocketTerminator/;
	
	use HashNet::MP::SocketWorker;
	use HashNet::MP::LocalDB;
	use HashNet::MP::PeerList;
	use HashNet::MP::MessageQueues;
	use HashNet::Util::Logging;
	use HashNet::Util::CleanRef;

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
	
	sub router_process_loop
	{
		my $self = shift;

		my $self_uuid  = $self->node_info->{uuid};

		#trace "MessageHub: Starting router_process_loop()\n";
		
		while(1)
		{
			#my @list = $self->pending_messages;
			my @list = pending_messages(incoming, nxthop => $self_uuid);
			#trace "MessageHub: router_process_loop: ".scalar(@list)." message to process\n";
			
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
					my $queued_msg = $queue->by_key(uuid => $rx_msg_uuid);
					$queue->del_row($queued_msg) if $queued_msg;

					trace "MessageHub: router_process_loop: Received MSG_CLIENT_RECEIPT for {$rx_msg_uuid}, receipt id {$msg->{uuid}}, lasthop $msg->{curhop}\n";
				}

				my @recip_list;

				my @peers = HashNet::MP::PeerList->peers;
				#debug "MessageHub: remote_nodes: ".Dumper(\@remote_nodes);

				my $last_hop_uuid = $msg->{curhop};
				
				if($msg->{bcast})
				{
					@recip_list = @peers;
					# list all known hubs, clients, etc
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

						# Message not to a peer directly connected (could be broadcast, or just to a client on another hub),
						# so until we develop a routing table mechanism, we just broadcast to all connected peers
						@recip_list = @peers;

						# If not store-forward, then we only want to send to peers currently online
						# since we dont want to store this message for any peers that are not currently
						# connect to this hub
						if(!$msg->{swfd})
						{
							@recip_list = grep { $_->{online} } @recip_list;
						}
					}
				}

				if($msg->{type} eq MSG_CLIENT_RECEIPT)
				{
					# If it's a broadcast client receipt, we grep out the last hop
					# so we dont just bounce it right back to the recipient
					@recip_list = grep { $_->uuid ne $last_hop_uuid } @peers;
				}

				debug "MessageHub: router_process_loop: Msg UUID $msg->{uuid} for data '$msg->{data}': recip_list: {".join(' | ', map { $_->{name}.'{'.$_->{uuid}.'}' } @recip_list)."}\n";

				foreach my $peer (@recip_list)
				{
					my @args =
					(
						$msg->{data},
						uuid	=> $msg->{uuid},
						hist	=> $msg->{hist},

						curhop	=> $self_uuid,
						nxthop	=> $peer->uuid,

						# Rewrwite the 'to' address if the msg is a broadcast msg AND the next hop is a 'client' because
						# clients just check the 'to' field to pickup messages
						# Clients do NOT check nxthop, just 'to' when picking up messages from the queue because
						# msgs could reach the client that are not broadcast and not to the client - they just
						# got sent to the client because the hub didn't know where the client was
						# connected - so we dont want the client to work with those messages.
						to	=> $msg->{bcast} && $peer->{type} eq 'client' ? $peer->uuid : $msg->{to},
						from	=> $msg->{from},
					 
						bcast	=> $msg->{bcast},
						sfwd	=> $msg->{sfwd},
						type	=> $msg->{type},
					);
					my $new_env = HashNet::MP::SocketWorker->create_envelope(@args);
					$self->outgoing_queue->add_row($new_env);
					#debug "MessageHub: router_process_loop: Msg UUID $msg->{uuid} for data '$msg->{data}': Next envelope: ".Dumper($new_env);
				}
					
			}

			sleep 0.25;
		}
		
	}
};
1;