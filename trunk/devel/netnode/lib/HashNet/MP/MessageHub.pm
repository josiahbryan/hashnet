{package HashNet::MP::MessageHub;
	
	use common::sense;

	use base qw/HashNet::MP::SocketTerminator/;

	use YAML::Tiny; # for load_config/save_config
	use UUID::Generator::PurePerl; # for node_info
	use Geo::IP; # for Geolocating our WAN address


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

	our $CONFIG_FILE = [qw#hashnet-hub.conf /etc/hashnet-hub.conf#];
	our $DEFAULT_CONFIG =
	{
		port	 => 8031,
		#uuid	 => undef,
		#name	 => undef,
		data_dir => '/var/lib/hashnet',
	};

	my @IP_LIST_CACHE;
	sub my_ip_list
	{
		return @IP_LIST_CACHE if @IP_LIST_CACHE;

		# Based on code from http://www.perlmonks.org/?node_id=53660
		my $interface;
		my %ifs;

		foreach ( qx{ (LC_ALL=C /sbin/ifconfig -a 2>&1) } )
		{
			$interface = $1 if /^(\S+?):?\s/;
			next unless defined $interface;
			$ifs{$interface}->{state} = uc($1) if /\b(up|down)\b/i;
			# NOTE Yes, I know - need to find a way to make compat with IPv6
			$ifs{$interface}->{ip}    = $1     if /inet\D+(\d+\.\d+\.\d+\.\d+)/i;
		}

		# Skip bridges because even though they are not technically the localhost interface,
		# if we have the same bridge ip on multiple machines (such as two machines that have
		# xen dom0 or VirtualBox installed), resp_reg_ip would change the bridgeip to localhost
		# since the same ip appears in both lists. (See resp_reg_ip())
		unless(`which brctl 2>&1` =~ /no brctl/)
		{
			foreach ( qx{ brctl show } )
			{
				$interface = $1 if /^(\S+?)\s/;
				next unless defined $interface && $interface ne 'bridge'; # first line is 'bridge name ...';
				delete $ifs{$interface};
			}
		}

		@IP_LIST_CACHE = ();
		foreach my $if (keys %ifs)
		{
			next if !defined $ifs{$if} || $ifs{$if}->{state} ne 'UP';
			my $ip = $ifs{$if}->{ip} || '';

			push @IP_LIST_CACHE, $ip if $ip;
		}

		return grep { $_ ne '127.0.0.1' } @IP_LIST_CACHE;
	}
	
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


	sub read_config
	{
		my $self = shift;

		if(ref($CONFIG_FILE) eq 'ARRAY')
		{
			my @files = @$CONFIG_FILE;
			my $found = 0;
			foreach my $file (@files)
			{
				if(-f $file)
				{
					#logmsg "DEBUG", "PeerServer: Using config file '$file'\n";
					$CONFIG_FILE = $file;
					$found = 1;
					last;
				}
			}

			if(!$found)
			{
				my $file = shift @$CONFIG_FILE;
				logmsg "WARN", "PeerServer: No config file found, using default location '$file'\n";
				$CONFIG_FILE = $file;
			}
		}
		else
		{
			#die Dumper $CONFIG_FILE;
		}

		#logmsg "DEBUG", "PeerServer: Loading config from $CONFIG_FILE\n";
		my $config = {};
		if(-f $CONFIG_FILE)
		{
			$config = YAML::Tiny::LoadFile($CONFIG_FILE);
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
			config => $self->{config},
		};
		#trace Dumper($self);
		
		logmsg "DEBUG", "PeerServer: Saving config to $CONFIG_FILE\n";
		YAML::Tiny::DumpFile($CONFIG_FILE, $config);

		return if ! $self->{node_info_changed_flag_file};

		# The timer loop will check for the existance of this file and push the node info into the storage engine
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
		my $set = sub
		{
			my ($k,$v) = @_;
			$inf->{$k} = $v;
			$changed = 1;
		};

		if(!$inf->{name})
		{
			my $name = `hostname`;
			$name =~ s/[\r\n]//g;
			$set->('name', $name);
		}

		if(!$inf->{uuid})
		{
			my $uuid = UUID::Generator::PurePerl->new->generate_v1->as_string();
			$set->('uuid', $uuid);
		}

# 		if(($inf->{port}||0) != $self->peer_port())
# 		{
# 			$set->('port', $self->peer_port());
# 		}

		{
			my $uptime = `uptime`;
			$uptime =~ s/[\r\n]//g;
			$set->('uptime', $uptime);
		}

		#$set->('hashnet_ver', $HashNet::StorageEngine::VERSION)
		#	if ($inf->{hasnet_ver} || 0) != $HashNet::StorageEngine::VERSION;


		#if(!$inf->{wan_ip})
		# Check WAN IP every time in case it changes
		{
			my $external_ip;

# 			my $external_ip = `lynx -dump "http://checkip.dyndns.org"`;
# 			$external_ip =~ s/.*?([\d\.]+).*/$1/;
# 			$external_ip =~ s/(^\s+|\s+$)//g;
#
			#$external_ip = `wget -q -O - "http://checkip.dyndns.org"`;
			$external_ip = `wget -q -O - http://dnsinfo.net/cgi-bin/ip.cgi`;
			if($external_ip =~ m/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/) {
				$external_ip = $1;
			}

			$external_ip = '' if !$external_ip;

			$set->('wan_ip', $external_ip)
				if ($inf->{wan_ip}||'') ne $external_ip;
		}

		# TODO: Geolocate IP
		# If we have the geoIP db on this machine, then geo using Geo::IP,
		# otherwise, post a message and see if another peer can answer for us
		# https://www.google.com/search?sourceid=chrome&ie=UTF-8&q=perl+geo+locate+ip#hl=en&pwst=1&sa=X&ei=RP88UObrJsnJ0QHjl4DgCA&ved=0CB0QvwUoAQ&q=perl+geolocate+ip&spell=1&bav=on.2,or.r_gc.r_pw.r_qf.&fp=5b96907402d9468b&biw=1223&bih=510
		# http://www.drdobbs.com/web-development/geolocation-in-perl/184416182
		# http://search.cpan.org/~borisz/Geo-IP-1.40/lib/Geo/IP.pm
		# http://www.maxmind.com/app/geolite
		if(!defined $inf->{geo_info_auto})
		{
			$inf->{geo_info_auto} = 1;
		}
		$inf->{geo_info_auto} += 0; # force-cast to number

		if($inf->{geo_info_auto} &&
		   $inf->{wan_ip})
		{
			my @files = ('/var/lib/hashnet/GeoLiteCity.dat','/usr/local/share/GeoIP/GeoLiteCity.dat','/tmp/GeoLiteCity.dat');

			my $ip_data_file = undef;
			foreach my $file (@files)
			{
				if(-f $file)
				{
					$ip_data_file = $file;
					#logmsg "TRACE", "PeerServer: Using geolocation datafile '$file'\n";
				}
			}

			if(!$ip_data_file)
			{
				my $url = 'http://geolite.maxmind.com/download/geoip/database/GeoLiteCity.dat.gz';
				my $dest = '/tmp/GeoLiteCity.dat';
				logmsg "INFO", "PeerServer: Downloading geolocation datafile from $url\n";
				system("wget -q -O - $url > $dest.gz");
				logmsg "INFO", "PeerServer: 'gunzip'ing $dest.gz\n";
				system("gunzip $dest");
				$ip_data_file = $dest;

				if(!-f $ip_data_file)
				{
					print STDERR "[ERROR] PeerServer: Error downloading or unzipping $dest - GeoLocating will not work.\n";
				}
			}

			if(-f $ip_data_file)
			{
				my $gi = Geo::IP->open($ip_data_file, GEOIP_STANDARD);
				my $record = $gi->record_by_addr($inf->{wan_ip});
# 				my $geo_info = join(', ',
# 					$record->country_code,
# 					$record->country_code3,
# 					$record->country_name,
# 					$record->region,
# 					$record->region_name,
# 					$record->city,
# 					$record->postal_code,
# 					$record->latitude,
# 					$record->longitude,
# 					$record->time_zone,
# 					$record->area_code,
# 					$record->continent_code,
# 					$record->metro_code);

				eval {
					my $geo_info = join(', ',
						$record->city || '',
						$record->region || '',
						$record->country_code || '',
						$record->latitude || '',
						$record->longitude || '');

					$set->('geo_info', $geo_info)
						if ($inf->{geo_info}||'') ne $geo_info;
				};
				if($@)
				{
					logmsg "INFO", "Error updating geo_info for wan '$inf->{wan_ip}': $@";
				}
			}
		}

		{
			my $ip_list = join(', ', grep { $_ ne '127.0.0.1' } $self->my_ip_list);
			$set->('lan_ips', $ip_list)
				if !$inf->{lan_ips} ne $ip_list;
		}

		if(!$inf->{distro})
		{
			my $distro = `lsb_release -d`;
			$distro =~ s/^Description:\s*//g;
			$distro =~ s/[\r\n]//g;
			$distro =~ s/(^\s+|\s+$)//g;
			$set->('distro', $distro);
		}

		if(!$inf->{os_info})
		{
			my $info = `uname -a`;
			$info =~ s/[\r\n]//g;
			$info =~ s/(^\s+|\s+$)//g;

			$set->('os_info', $info);
		}

		$self->save_config if $changed;
		#logmsg "INFO", "PeerServer: Node info audit done.\n";

		undef $set;
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

		#trace "MessageHub: Starting router_process_loop()\n";
		my $self_uuid  = $self->node_info->{uuid};
		
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
				local *@;
				eval { $self->route_message($msg); };
				trace "MessageHub: Error in route_message(): $@" if $@;
			}

			#$self->incoming_queue->del_batch(\@list);
			#$self->incoming_queue->unlock_file;
			$self->outgoing_queue->resume_update_saves;

			sleep 0.25;
		}
	}

	sub route_message
	{
		my $self = shift;
		my $msg = shift;
		my $self_uuid  = $self->node_info->{uuid};
		
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
};
1;