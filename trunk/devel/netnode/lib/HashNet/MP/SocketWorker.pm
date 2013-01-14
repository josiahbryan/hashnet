use common::sense;
{package HashNet::MP::SocketWorker;

	#use base qw/HashNet::Util::MessageSocketBase/;
	use HashNet::Util::MessageSocketBase;
	our @ISA = qw( HashNet::Util::MessageSocketBase );
	
	#use JSON qw/to_json from_json/;
	# For compat with older servers
	use JSON::PP qw/encode_json decode_json/;
	#use JSON qw/to_json from_json/;
	sub to_json   { encode_json(shift) } 
	sub from_json { decode_json(shift) }
	
	
	use Data::Dumper;
	
	use Time::HiRes qw/time sleep/;

	use Carp qw/carp croak/;
	use POSIX qw( WNOHANG );

	use Storable qw/store retrieve/; # WAN IP cache

	use HashNet::MP::PeerList;
	use HashNet::MP::LocalDB;
	use HashNet::MP::MessageQueues;
	use HashNet::MP::GlobalDB;
	
	use HashNet::Util::Logging;
	use HashNet::Util::CleanRef;
	use HashNet::Util::SNTP;

	use Geo::IP; # for Geolocating our WAN address
	use UUID::Generator::PurePerl; # for use in gen_node_info
	
	sub MSG_NODE_INFO	{ 'MSG_NODE_INFO' }
	sub MSG_INTERNAL_ERROR	{ 'MSG_INTERNAL_ERROR' }
	sub MSG_ACK		{ 'MSG_ACK' }
	sub MSG_USER		{ 'MSG_USER' }
	sub MSG_OFFLINE		{ 'MSG_OFFLINE' }
	sub MSG_PING		{ 'MSG_PING' }
	sub MSG_PONG		{ 'MSG_PONG' }
	sub MSG_UNKNOWN		{ 'MSG_UNKNOWN' }

	# Can store our state_handle data in another db file if needed/wanted - just set this to the path of the file to use (autocreated)
	our $STATE_HANDLE_DB = undef;

	# Used to index the SocketWorkers for the running app
	our $STARTUP_PID = $$;
	
	# Class-wide hash of arrayrefs of coderefs to process new messages
	my %MsgHandlers;

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

		
	# Simple utility method to auto-generate the node_info structure based on $0
	my $UUID_GEN = UUID::Generator::PurePerl->new(); 
	sub gen_node_info
	{
	
		my $dbh = HashNet::MP::LocalDB->handle;
		my $node_info = $dbh->{auto_clients}->{$0};
		if(!$node_info)
		{
			$node_info->{name} = $0;
			$node_info->{uuid} = $UUID_GEN->generate_v1->as_string();
			$node_info->{type} = 'client';
			$dbh->{auto_clients}->{$0} = $node_info;
		}
		
		#print STDERR "Debug: gen_node_info: node_info:".Dumper($node_info);

		# Return a 'clean' hash so user can use this ref across forks
		return clean_ref($node_info);
	}
	
	sub new
	{
		my $class = shift;
		
		# Allow single argument of $socket, assume no forking
		if(@_ == 1)
		{
			@_ = (
				sock    => $_[0],
				no_fork => 1
			);
		}

		my %opts = @_;
		
		# If we DON'T set auto_start to 0,
		# then ::new() may never return if
		# the caller set {no_fork} to a TRUE
		# value - ::new() would call start()
		# which would go right into a process_loop()
		# and we would never get the stack back from
		# new() until process_loop() ends.
		# By setting auto_start() to 0, we get the
		# chance to do other things before
		# 'risking' loosing the process by calling
		# start() at the end of our new()
		my $old_auto_start = $opts{auto_start}; 
		$opts{auto_start} = 0;
		
		# Auto-generate node_info as needed
		$opts{node_info} = $class->gen_node_info if !$opts{node_info};

		#die Dumper \%opts;
		
		my $self = $class->SUPER::new(%opts);
		#my $self = HashNet::MP::MessageSocketBase->new(%opts);
		
		# Create a UUID for this *object instance* to use to sync state across forks via LocalDB
		$self->{state_uuid} = $UUID_GEN->generate_v1->as_string();

		# Update time offset via SNTP
		$self->update_time_offset;

		# Add time_offset to node_info for other nodes in the network to use if every needed (not used at the moment)
		$self->{node_info}->{time_offset} = $self->time_offset;

		# Set startup flag to 0, will be set to 0.5 when connected and 1 when rx'd node_info from other side
		$self->state_update(1);
		$self->state_handle->{started} = 0;
		$self->state_update(0);

# 		# Integrate with GlobalDB if requested
# 		if($opts{use_globaldb})
# 		{
# 			$self->{globaldb} = HashNet::MP::GlobalDB->new(sw => $self);
# 		}

		# Allow the caller to call start() if desired
		$self->start_tx_loop();
		$self->start unless defined $old_auto_start && !$old_auto_start;
		 
		return $self;
	}

	sub state_handle
	{
		my $self = shift;

		#trace "SocketWorker: state_handle: Access in $$\n";
		my $ref = HashNet::MP::LocalDB->handle($STATE_HANDLE_DB);

		$ref->load_changes;

		my $changes = 0;
		
		if(!$ref->{socketworker})
		{
			$ref->{socketworker} = {};
			$changes = 1;
		}
		
		my $id = $self->{state_uuid};
		my $sw = $ref->{socketworker};

		if(!$sw->{$id})
		{
			$sw->{$id} = {};
			$changes = 1;
		}

		$ref->save_data if $changes;

		#$self->{state_handle} = { ref => $ref, hdl => $sw->{$id} };
		#return $self->{state_handle}->{hdl};
		return $sw->{$id};
	}


	sub state_update
	{
		my $self = shift;
		my $flag = shift;
		my $ref = HashNet::MP::LocalDB->handle($STATE_HANDLE_DB);
		$ref->update_begin if  $flag;
		$ref->update_end   if !$flag;
	}

	sub DESTROY
	{
		my $self = shift;
		my $ref= HashNet::MP::LocalDB->handle($STATE_HANDLE_DB);

# 		my $env = $self->create_envelope($self->{node_info}->{name}.' Shutdown',
# 						to => '*',
# 						sfwd => 0,
# 						bcast => 1,
# 						type => MSG_OFFLINE);
# 		$self->send_message($env);
		#print STDERR Dumper $env;

		# Remove the state data from the database
		$ref->update_begin;
		delete $ref->data->{socketworker}->{$self->{state_uuid}};
		$ref->update_end;

		# Kill any receiver forks
# 		my @fork_pids = @{ $self->{receiver_forks} || [] };
# 		kill 15, $_ foreach @fork_pids;

		#trace "SocketWorker: DESTROY: Shutting down\n";
		#trace "SocketWorker: DESTROY: Callstack: ".get_stack_trace();
	}

	sub bad_message_handler
	{
		my $self    = shift;
		my $bad_msg = shift;
		my $error   = shift;
		
		print STDERR "bad_message_handler: '$error' (bad_msg: $bad_msg)\n";
		$self->send_message({ msg => MSG_INTERNAL_ERROR, error => $error, bad_msg => $bad_msg });
	}

	sub node_info
	{
		my $self = shift;
		$self->check_node_info(shift);
		return $self->{node_info};
	}

	sub check_node_info
	{
		my $self = shift;
		my $force = shift || 0;

		return if !$force && $self->{_node_info_audited};
		$self->{_node_info_audited} = 1;

		$self->{node_info} ||= {};

		#logmsg "TRACE", "PeerServer: Auditing node_info() for name, UUID, and IP info\n";

		my $inf = $self->{node_info};

		$self->update_node_info($inf);

		$inf->{type} = 'client' unless $inf->{type} eq 'hub';

		#logmsg "INFO", "PeerServer: Node info audit done.\n";
	}

	sub update_node_info
	{

		#trace "SocketWorker: update_node_info: stack: ".get_stack_trace();
		# Fields:
		# - Host Name
		# - WAN IP
		# - Geo locate
		# - LAN IPs
		# - MAC(s)?
		# - Host UUID
		# - OS Info

				
		my $self = shift;
		my $inf = shift;

		my $changed = 0;

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
			$uptime =~ s/(^\s+|\s+$|[\r\n])//g;
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
			my $wan_cache_file = '/tmp/mywanip.data';
			my $wan_cache;
			eval { $wan_cache = -f $wan_cache_file ? retrieve($wan_cache_file) : undef; };
			
			$wan_cache = {} if !$wan_cache;
			
			# Max time to cache IP
			my $max_time = 60 * 60;
			
			if(!$wan_cache->{wan_ip} || 
			    time - $wan_cache->{timestamp} > $max_time)
			{
				
				trace "SocketWorker: update_node_info(): Looking up WAN IP ...\n";
				#$external_ip = `wget -q -O - "http://checkip.dyndns.org"`;
				$external_ip = `wget -q -O - http://dnsinfo.net/cgi-bin/ip.cgi`;
				if($external_ip =~ m/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/) {
					$external_ip = $1;
				}
	
				$external_ip = '' if !$external_ip;
				trace "SocketWorker: update_node_info(): WAN IP is: '$external_ip'\n";
				
				# Cache IP
				store({ wan_ip => $external_ip, timestamp => time() }, $wan_cache_file);
			}
			else
			{
				$external_ip = $wan_cache->{wan_ip};
			}
			

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

			my $download_retried = 0;
			RE_DOWNLOAD_DATAFILE:
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
				#trace "SocketWorker: update_node_info(): Using \$ip_data_file: '$ip_data_file'\n";
				
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
					my $gi = Geo::IP->open($ip_data_file, GEOIP_STANDARD);
					my $record = $gi->record_by_addr($inf->{wan_ip});
					my $geo_info = join(', ',
						$record->city || '',
						$record->region || '',
						$record->country_code || '',
						$record->latitude || '',
						$record->longitude || '');

					$set->('geo_info', $geo_info)
						if ($inf->{geo_info}||'') ne $geo_info;
				};
				if(my $err = $@)
				{
					die $@;
					logmsg "INFO", "Error updating geo_info for wan '$inf->{wan_ip}': $@";
					if($err =~ /is corrupt/ && !$download_retried)
					{
						$download_retried = 1;
						goto RE_DOWNLOAD_DATAFILE;
					}
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

		undef $set;

		return $changed;
	}

	sub create_envelope
	{
		my $self = shift;
		my $data = shift;

		@_ = %{ $_[0] || {} } if @_ == 1 && ref $_[0] eq 'HASH';

		@_ =  ( to => $_[0] ) if @_ == 1;
		
		my %opts = @_;
		
		#debug "SocketWorker: create_envelope: orig opts: ".Dumper(\%opts); 

		if(!$opts{to} && $opts{nxthop})
		{
			$opts{to} = $opts{nxthop};
		}

		if(!$opts{to} && $self->peer_uuid)
		{
			$opts{to} = $self->peer_uuid;
		}
		
		if(!$opts{nxthop} && $opts{to})
		{
			$opts{nxthop} = $opts{to};
		}
		
		if(!$opts{nxthop} && $self->peer_uuid)
		{
			$opts{nxthop} = $self->peer_uuid;
		}

		if(!$opts{to})
		{
			#print STDERR Dumper $self;
			Carp::cluck "create_envelope: No destination given (either no to=>X, no 2nd arg, or no self->peer), therefore no envelope created";
			return undef;
		}

		if(!$opts{from})
		{
			$opts{from} = $self->uuid;
		}
		
		if(!$opts{curhop} && $opts{from})
		{
			$opts{curhop} = $opts{from};
		}

		if(!$opts{curhop})
		{
			$opts{curhop} = $self->uuid;
		}

		$opts{hist} = [] if !$opts{hist};

		push @{$opts{hist}},
		{
			from => $opts{curhop} || $opts{from}, #$self->uuid,
			to   => $opts{nxthop} || $opts{to},
			time => $self->sntp_time(),
		};
		

		my $env =
		{
			time	=> $self->sntp_time(),
			uuid	=> $opts{uuid} || $UUID_GEN->generate_v1->as_string(),
			# re_uuid is the uuid of the envelope to which this envelope is a reply (if any, can be undef - usually is)
			re_uuid => $opts{re_uuid} || undef,
			# From is the hub/client where this envelope originated
			from    => $opts{from},
			# To is the hub/client where this envelope is destined
			to	=> $opts{to},
			# Nxthop is the next hub/client this envelope is destined for
			nxthop	=> $opts{nxthop}, # || $opts{to},
			# Curhop is this current client
			curhop	=> $opts{curhop}, # || $opts{from},
			# If bcast is true, the next hub that gets this envelope
			# will copy it and broadcast it to each of its hubs/clients
			bcast	=> $opts{bcast} || 0,
			# If false, the hub will not store it if the client/hub is currently offline - just drops the envelope
			sfwd	=> defined $opts{sfwd} ? $opts{sfwd} : 1, # store n forward
			# Type is only relevant for internal types to SocketWorker - MSG_USER are just put into the incoming queue for the hub to route
			type	=> $opts{type} || MSG_USER,
			# Data is the actual content of the message
			data	=> $data,
			# _att is handled specially by the underlying MessageSocketBase class - it's never encoded to JSON,
			# it's just transmitted raw as an 'attachment' to the JSON message (this envelope) - it's removed from the envelope,
			# transmitted (envelope as JSON, _att as raw data), then re-added to the envelope at the other end in the _att key on that side
			_att	=> $opts{_att} || undef,
			# History of where this envelope/data has been
			hist	=> clean_ref($opts{hist}),
				# use clean_ref because history was getting changed by future calls to create_envelope() for broadcast messages to other hosts
		};

		return $env;
	}
	
	sub create_client_receipt
	{
		my $self = shift;
		my $msg         = shift || {};
		my $from_uuid   = shift;
		my $nxthop_uuid = shift;
		$from_uuid   = $self->uuid      if !$from_uuid   && ref $self;
		$nxthop_uuid = $self->peer_uuid if !$nxthop_uuid && ref $self;
		my @args =
		(
			{
				msg_uuid    => $msg->{uuid},
				msg_hist    => $msg->{hist},
				client_uuid => $from_uuid,
			},
			type	=> 'MSG_CLIENT_RECEIPT',
			nxthop	=> $nxthop_uuid, 
			curhop	=> $from_uuid,
			from    => $from_uuid,
			to	=> '*',
			bcast	=> 1,
			sfwd	=> 0,
		);

		if(!$nxthop_uuid)
		{
			error "SocketWorker: create_client_receipt: \$nxthop_uuid (third arg) is undef, not creating envelope.\n";
			error "SocketWorker: create_client_receipt: called from: ".print_stack_trace();
			return undef;
		}
		
		return $self->create_envelope(@args);
	}

	sub check_env_hist
	{
		my $env = shift;
		my $to = shift;
		return if !ref $env;

		my @hist = @{$env->{hist} || []};
		@hist = @hist[0..$#hist-1]; # last line of hist is the line for X->(this server), so ignore it
		#warn Dumper \@hist;
		foreach my $line (@hist)
		{
			return 1 if $line->{to} eq $to;
		}
		return 0;
	}
	
	sub connect_handler
	{
		my $self = shift;
		
		trace "SocketWorker: Sending MSG_NODE_INFO\n";
		my $env = $self->create_envelope($self->{node_info}, to => '*', type => MSG_NODE_INFO);
		#use Data::Dumper;
		#print STDERR Dumper $env;
		$self->send_message($env);

		$self->state_update(1);
		$self->state_handle->{online} = 0.5;
		$self->state_update(0);
	}

	
	sub disconnect_handler
	{
		my $self = shift;
		
		trace "SocketWorker: disconnect_handler: Peer {".$self->peer_uuid."} disconnected\n"; #\n\n\n\n\n"; #peer: $self->{peer}\n";
		#print STDERR "\n\n\n\n\n";
		$self->{peer}->set_online(0) if $self->{peer};

		$self->state_update(1);
		$self->state_handle->{online} = 0;
		$self->state_update(0);
	}
	
	sub process_loop_start_hook
	{
		my $self = shift;
		$self->state_update(1);
		$self->state_handle->{tx_loop_pid} = $$;
		$self->state_update(0);
	}
	
	sub dispatch_message
	{
		my $self = shift;
		my $envelope = shift;
		my $second_part = shift;
		
		#print STDERR "dispatch_message: envelope: ".Dumper($envelope)."\n";
		
		#$self->send_message({ received => $envelope });
		$envelope->{_att} = $second_part if defined $second_part;
		$envelope->{_rx_time} = $self->sntp_time();
				
		my $msg_type = $envelope->{type};
		info "SocketWorker: dispatch_msg: New incoming $envelope->{type} envelope, UUID {$envelope->{uuid}}, Data: '$envelope->{data}'\n";

		if($msg_type eq MSG_PING)
		{
			if(check_env_hist($envelope, $self->uuid))
			{
				info "SocketWorker: dispatch_msg: MSG_PING: Ignoring this ping, it's been here before\n";
			}
# 			elsif($envelope->{from} eq $self->uuid)
# 			{
# 				info "SocketWorker: dispatch_msg: MSG_PING: Not responding to self-ping\n";
# 			}
			else
			{
				my @args =
				(
					{
						msg_uuid    => $envelope->{uuid},
						msg_hist    => $envelope->{hist},
						node_info   => $self->node_info,
						pong_time   => $self->sntp_time(),
					},
					type	=> MSG_PONG,
					nxthop	=> $self->peer_uuid,
					curhop	=> $self->uuid,
					to	=> $envelope->{from},
					bcast	=> 0,
					sfwd	=> 0,
				);
				my $new_env = $self->create_envelope(@args);
				#trace "ClientHandle: incoming_messages: Created MSG_PONG for {$envelope->{uuid}}\n";#, data: '$msg->{data}'\n"; #: ".Dumper($new_env, \@args)."\n";
				my $delta = $new_env->{data}->{pong_time} - $envelope->{data}->{ping_time};
				info "SocketWorker: dispatch_msg: MSG_PING, UUID {$envelope->{uuid}}, sending MSG_PONG back to {$envelope->{from}} ($envelope->{data}->{node_info}->{name}), ping->pong time: ".sprintf('%.03f', $delta)." sec\n";

				#use Data::Dumper;
				#print STDERR Dumper $envelope;

				$self->send_message($new_env);
			}
		}
		# We let MSG_PINGs fall thru to be dropped in the incoming queue as well so they can be processed by the MessageHub

		# Store return value of check_env_hist() for use later in adding envelope to queue 
		my $check_hist = check_env_hist($envelope, $self->uuid);
		
		# Hook for custom message handlers to be called based on the type of message
		my $consumed = 0;
		if(!$check_hist)
		{
			if(my $arrayref = $MsgHandlers{$msg_type})
			{
				my @list = @{$arrayref || []};
				debug "SocketWorker: dispatch_msg: Found ".scalar(@list)." handlers for msg_type '$msg_type'\n";
				foreach my $coderef (@list)
				{
					my $flag = $coderef->($envelope);
					
					$self->send_message($self->create_client_receipt($envelope))
						if $self->peer->{type} eq 'hub';
					
					$consumed = 1 if $flag == 1;
				}
			}
		}
		
		if($consumed)
		{
			trace "SocketWorker: dispatch_msg: Custom coderef consumed message ${msg_type}{$envelope->{uuid}}, not enqueing\n";
		}
		elsif($msg_type eq MSG_ACK)
		{
			# Just ignore ACKs for now
			return;
		}
		elsif($msg_type eq MSG_NODE_INFO)
		{
			my $node_info = $envelope->{data};
			info "SocketWorker: dispatch_msg: Received MSG_NODE_INFO for remote node '$node_info->{name}'\n";

			my $peer;
			if(!$self->{peer} &&
			    $self->{peer_host})
			{
				$self->{peer} = HashNet::MP::PeerList->get_peer_by_host($self->{peer_host});
			}
			
			if($self->{peer})
			{
				$peer = $self->peer;
				$peer->merge_keys(clean_ref($node_info));
			}
			else
			{
				$peer = HashNet::MP::PeerList->get_peer_by_uuid(clean_ref($node_info));
				$self->{peer} = $peer;
			}

			#print STDERR Dumper $peer, $node_info;
			
			$peer->set_online(1);

			#$self->send_message($self->create_envelope({ack_msg => MSG_NODE_INFO, text => "Hello, $node_info->{name}" }, type => MSG_ACK));

			$self->state_update(1);
			$self->state_handle->{remote_node_info} = $node_info;
			$self->state_handle->{online} = 1;
			$self->state_update(0);

			$self->_rx_copy_to_listen_queues($envelope);

			#trace "SocketWorker: state_handle: ".Dumper($self);

		}
		else
		{
			if($check_hist) #check_env_hist($envelope, $self->uuid))
			{
				info "SocketWorker: dispatch_msg: NOT enquing envelope, history says it was already sent here.\n"; #: ".Dumper($envelope);
			}
			else
			{
				incoming_queue()->add_row($envelope);
				
				$self->_rx_copy_to_listen_queues($envelope);

				#info "SocketWorker: dispatch_msg: New incoming envelope added to queue: ".Dumper($envelope);
				#info "SocketWorker: dispatch_msg: New incoming $envelope->{type} envelope, UUID {$envelope->{uuid}}, Data: '$envelope->{data}'\n";
				#print STDERR Dumper $envelope;
			}
		}
	}

	# TODO: Update Message Socket Base to honor failure to lock
	sub bulk_read_start_hook
	{
		my $self = shift;
		#trace "SocketWorker: bulk_read_start_hook()\n";# if $self->{node_info}->{uuid} eq '1509280a-5687-4a6b-acc8-bd58beaccbae';
		return incoming_queue()->begin_batch_update;
		#trace "SocketWorker: bulk_read_start_hook() [done]\n"
	}
	
	sub bulk_read_end_hook
	{
		my $self = shift;
		#trace "SocketWorker: bulk_read_end_hook() - queue size: ".incoming_queue()->size()."\n";# if $self->{node_info}->{uuid} eq '1509280a-5687-4a6b-acc8-bd58beaccbae';
		#trace "SocketWorker: bulk_read_end_hook(): ".Dumper(incoming_queue());
		incoming_queue()->end_batch_update;
	}

	sub update_time_offset
	{
		my $self = shift;
		$self->state_update(1);

		# (undef, 1) tells sync_time() to only get the offset, not to try and adjust the time
		$self->state_handle->{time_offset} = HashNet::Util::SNTP->sync_time(undef, 1);
		$self->state_update(0);
	}

	sub time_offset { shift->state_handle->{time_offset} }
	sub sntp_time   { time() + shift->time_offset }

	sub send_ping
	{
		my $self = shift;
		my $uuid_to = shift;
		my $max   = shift || 5;
		my $speed = shift || 0.1;

		my $start_time = $self->sntp_time();
		my $bcast = $uuid_to ? 0 : 1;

		$self->wait_for_start; # if !$self->is_started;

		my @args =
		(
			{
				node_info   => $self->node_info,
				ping_time   => $start_time,
			},
			type	=> MSG_PING,
			nxthop	=> $self->peer_uuid,
			curhop	=> $self->uuid,
			to	=> $uuid_to || '*',
			bcast	=> $bcast,
			sfwd	=> 0,
		);
		my $new_env = $self->create_envelope(@args);

		info "SocketWorker: send_ping: Sending MSG_PING" . ($uuid_to ? " to $uuid_to" : " as a broadcast ping"). " via hub ".$self->peer_uuid." (".$self->state_handle->{remote_node_info}->{name}.")\n";
		
		$self->send_message($new_env);

		#$self->outgoing_queue->add_row($new_env);
		#$self->wait_for_send();

		my $uuid  = $self->uuid;
		my $queue = incoming_queue();
		if(!$bcast)
		{
			# Wait for a single pong back
			my $time  = time;
			while(time - $time < $max)
			{
				#my $flag = defined ( $queue->by_key(to => $uuid, type => 'MSG_PONG', from => $uuid_to) );
				my $msg = $queue->by_key(to => $uuid, type => 'MSG_PONG', from => $uuid_to);
				if(!$self->state_handle->{online})
				{
					error "SocketWorker: send_ping; child thread gone away, not waiting anymore\n";
					last;
				}
				
				if(defined $msg)
				{
					#print STDERR "SocketWorkeR: wait for ping: got pong: ".Dumper($msg);
				}
				
				my $flag = 1 if defined $msg;

				#trace "SocketWorker: wait_for_receive: Have $cnt, want $count ...\n";
				last if $flag;
				sleep $speed;
			}
		}
		else
		{
			# Just wait for broadcast pings to come in to the child fork
			sleep $max;
		}

		#my @list = $queue->by_key(to => $uuid, type => 'MSG_PONG');
		my @list = $queue->by_key(type => 'MSG_PONG');
		@list = sort { $a->{time} cmp $b->{time} } @list;

		#trace "SocketWorker: Ping dump: ".Dumper(\@list);

		my @return_list = map { clean_ref($_) } grep { defined $_ } @list;

		$queue->del_batch(\@list);

		my $final_rx_time = $self->sntp_time();

# 		if(!$bcast)
# 		{
# 			return () if !@return_list;
# 			my $msg = shift @return_list;
# 			my $pong_time = $msg->{data}->{pong_time};
# 			my $delta = $pong_time - $start_time;
# 			my $rx_delta = $final_rx_time - $start_time;
# 			info "SocketWorker: Ping $uuid_to: ".sprintf('%.03f', $delta)." sec (total tx/rx time: ".sprintf('%.03f', $rx_delta)." sec)\n";
# 			#return $delta;
# 			
# 			my $out =
# 			{
# 				start_t   => $start_time,
# 				msg       => $msg,
# 				node_info => $msg->{data}->{node_info},
# 				time      => $delta,
# 				rx_delta  => $rx_delta,
# 			};
# 			
# 			return ($out);
# 		}
# 		else
# 		{
			return () if !@return_list;

			my $rx_delta = $final_rx_time - $start_time;
			my @output;
			foreach my $msg (@return_list)
			{
				my $pong_time = $msg->{data}->{pong_time};
				my $delta = $pong_time - $start_time;

				my $out =
				{
					start_t   => $start_time,
					msg       => $msg,
					node_info => $msg->{data}->{node_info},
					time      => $delta,
					rx_delta  => $rx_delta,
				};

				push @output, $out;
				info "SocketWorker: Broadcast Ping: ".sprintf('%.03f', $delta)." sec to '$out->{node_info}->{name}' \t {$out->{node_info}->{uuid}} \n";
			}

			return @output;
#		}
	}
	

	sub is_started { shift->state_handle->{online} == 1 }
	
	sub wait_for_start
	{
		my $self = shift;
		my $max   = shift || 4;
		my $speed = shift || 0.1;
		#trace "SocketWorker: wait_for_start: Enter: ".$self->state_handle->{started}."\n";
		my $time  = time;
		sleep $speed while time - $time < $max and
			     $self->state_handle->{online} != 1;

		# Return 1 if started, or <1 if not yet completely started
		my $res = $self->state_handle->{online};
		#trace "SocketWorker: wait_for_start: Exit, res: $res\n";
		return $res;
	}

	sub wait_for_send
	{
		my $self  = shift;
		my $max   = shift || 4;
		my $speed = shift || 0.1;
		my $uuid  = shift || $self->peer_uuid;
		my $queue = outgoing_queue();
		my $res = defined $queue->by_field(nxthop => $uuid) ? 0 : 1;
		#trace "SocketWorker: outgoing_queue dump ($uuid): ".Dumper($queue);
		#trace "SocketWorker: wait_for_send: Enter ($uuid), res: $res\n";
		my $time  = time;
		sleep $speed while time - $time < $max
			       #and !$queue->has_external_changes # check is_changed first to prevent having to re-load data every time if nothing changed
		               and defined $queue->by_field(nxthop => $uuid);
		# Returns 1 if all msgs sent by end of $max, or 0 if msgs still pending
		$res = defined $queue->by_field(nxthop => $uuid) ? 0 : 1;
		#trace "SocketWorker: outgoing_queue dump ($uuid): ".Dumper($queue);
		#trace "SocketWorker: wait_for_send: Exit ($uuid), res: $res\n";
		#trace "SocketWorker: wait_for_send: All messages sent.\n" if $res;
		return $res;
	}

	sub wait_for_receive
	{
		my $self  = shift;
# 		my $count = shift || 1;
# 		my $max   = shift || 4;
# 		my $speed = shift || 0.01;
		
		@_ = ( count => $_[0] ) if @_ == 1;
		my %opts  = @_;
		
		my $count = $opts{msgs}    || $opts{count} || 1;
		my $max   = $opts{timeout} || $opts{max}   || 4;
		my $speed = $opts{speed}   ||                 0.01;
		my $type  = $opts{type}    ||                 undef;
		my $uuid  = $opts{uuid}    ||                 $self->uuid;
		
		#trace "SocketWorker: wait_for_receive: Enter (to => $uuid), count: $count, max: $max, speed: $speed\n";
		my $queue = incoming_queue();
		my $time  = time;
		
		$self->wait_for_start if ref $self; # if $self->state_handle->{online} == 0.5;

# 		sleep $speed while time - $time < $max
# 		             and !$queue->has_external_changes;  # check has_external_changes first to prevent having to re-load data every time if nothing changed
#
# 		$queue->shared_ref->load_changes;

		#sleep $speed while time - $time < $max
		#               and scalar ( $queue->all_by_key(to => $uuid) ) < $count;
		while(time - $time < $max)
		{
			my $cnt = 0;
			if($type)
			{
				$cnt = scalar ( $queue->all_by_key(to => $uuid, type => $type) );
			}
			else
			{
				$cnt = scalar ( $queue->all_by_key(to => $uuid) );
			}
			
			unless(kill 0, $self->state_handle->{tx_loop_pid})
			{
				error "SocketWorker: wait_for_receive: SocketWorker tx loop PID ".$self->state_handle->{tx_loop_pid}." gone away, not waiting anymore\n";
				return $cnt;
			}

			#trace "SocketWorker: wait_for_receive: Have $cnt, want $count ...\n";
			last if $cnt >= $count;
			sleep $speed;
		}

		# Returns 1 if at least one msg received, 0 if incoming queue empty
		my $res;
		if($type)
		{
			$res = scalar ( $queue->all_by_key(to => $uuid, type => $type) );
		}
		else
		{
			$res = scalar $queue->all_by_key(to => $uuid);
		}
		
		#trace "SocketWorker: wait_for_receive: Exit, res: $res\n";
		#print STDERR "ClientHandle: Dumper of queue: ".Dumper($queue);
		#trace "SocketWorker: wait_for_receive: All messages received.\n" if $res;
		return $res;
	}


	
	sub peer { shift->{peer} }

	sub peer_uuid { shift->state_handle->{remote_node_info}->{uuid} }
	sub uuid      { shift->node_info->{uuid} }
	
	# Returns a list of pending messages to send using send_message() in process_loop
	use Data::Dumper;
	sub pending_messages
	{
		my $self = shift;
		#return () if !$self->peer;

 		my $uuid  = $self->peer_uuid; #$self->peer->uuid;
		return () if !$uuid;
		#trace "SocketWorker: pending_messages: uuid '$uuid' - querying...\n";
		#trace Dumper $self->state_handle;
		my @res = HashNet::MP::MessageQueues->pending_messages(outgoing, nxthop => $uuid, no_del => 1);
		#trace "SocketWorker: pending_messages: uuid: $uuid, ".Dumper(\@res);# if @res;
		#trace "SocketWorker: pending_messages: uuid: $uuid, ".Dumper(outgoing_queue());# if @res;
		
		# Somehow, empty hashes are getting into the outgoing queue...need to track down...
		@res = grep { $_->{uuid} } @res;
		
		# Check envelope history on this side so as to not cause unecessary traffice
		# if this envelope would just be rejected by the check_env_hist() above on the receiving side 
		#@res = grep { !check_env_hist($_, $uuid) } @res;
		
		return @res;
	}

	sub messages_sent
	{
		my $self = shift;
		my $batch = shift;
		$self->outgoing_queue->del_batch($batch);
	}

	# NOTE: This only works BEFORE
	# a SocketWorker is constructed - after it's called,
	# the forked listener thread will NOT see any changes
	# made to the %MsgHandlers hash.
	sub reg_msg_handler
	{
		my $class = shift;
		my $msg_name = shift;
		my $coderef = shift;
		
		#trace "SocketWorker: Registering msg '$msg_name': $coderef\n";

		$MsgHandlers{$msg_name} ||= [];
		push @{ $MsgHandlers{$msg_name} }, $coderef;
	}
	
	sub reg_handlers
	{
		my $class = shift;
		my %msgs = @_;
		$class->reg_msg_handler($_, $msgs{$_}) foreach keys %msgs;
	}
	
	sub _rx_register_listener
	{
		my $self = shift;
		my $msg_name = shift;
		my $pid = shift;
		my $ref = HashNet::MP::LocalDB->handle();

		# Prune old listener processes that may have gone away
		my %pid_hash = %{ $ref->{socketworker}->{rx_listeners}->{$msg_name} || {} };
		$self->_rx_validate_pid($msg_name, $_) foreach keys %pid_hash;

		# Register the new $pid with $msg_name
		$ref->update_begin;
		$ref->{socketworker}->{rx_listeners}->{$msg_name}->{$pid} = 1;
		$ref->update_end;
	}

	sub _rx_listen_queues_for_msg
	{
		my $self = shift;
		my $msg_name = shift;

		my $ref = HashNet::MP::LocalDB->handle();
		$ref->load_changes;

		my %pid_hash = %{ $ref->{socketworker}->{rx_listeners}->{$msg_name} || {} };
		my @pids = keys %pid_hash;

		# Only return queues for PIDs that are still alive (also prunes old PIDs)
		my @valid_pids;
		foreach my $pid (@pids)
		{
			push @valid_pids, $pid if $self->_rx_validate_pid($msg_name, $pid);
		}
		
		my @queues = map { msg_queue('listeners/'.$_) } grep { $_ } @pids;
		return @queues;
	}

	sub _rx_validate_pid
	{
		my ($self, $msg_name, $pid) = @_;
		
		# See http://perldoc.perl.org/functions/kill.html "If SIGNAL is zero..." for why this works
		return 1 if kill 0, $pid;

		$self->_rx_deregister_listener($msg_name, $pid);
		return 0;
	}

	sub _rx_deregister_listener
	{
		my $self = shift;
		my $msg_name = shift;
		my $pid = shift;
		
		return if !$pid;

		my $ref = HashNet::MP::LocalDB->handle();
		if($ref->update_begin)
		{
	
			# $pid no longer valid, automatically de-register it
			delete $ref->{socketworker}->{rx_listeners}->{$msg_name}->{$pid};
	
			# Even if another process with the same PID registers, we dont want stale messages laying in the queue
			# So we remove the old file.
			my $queue = msg_queue('listeners/'.$pid);
			$queue->shared_ref->delete_file;
	
			$ref->update_end;
		}
	}

	sub _rx_copy_to_listen_queues
	{
		my $self = shift;
		my $msg = shift;

		my @queues = $self->_rx_listen_queues_for_msg($msg->{type});
		return if !@queues;

		$_->add_row(clean_ref($msg)) foreach @queues;
	}
	
	sub rx_listen_queue
	{
		my $self = shift;
		my $pid  = shift;
		return undef if !$pid;
		return msg_queue('listeners/'.$pid)
	}
	
	sub fork_receiver
	{
		my $self = shift;
		my %msg_subs = @_;

		my $speed = 0.25;
		$speed = $msg_subs{speed} and delete $msg_subs{speed} if $msg_subs{speed} > 0; # speed of <0 still is boolean true, so eliminate <0 with >0

		my $uuid = undef;
		$uuid = $msg_subs{uuid}   and delete $msg_subs{uuid}  if $msg_subs{uuid};
		
		my @msg_names = keys %msg_subs;
		my $msg_name  = @msg_names > 1 ? '('.join('|', @msg_names).')' : $msg_names[0];

		if(!$uuid)
		{
			if(!ref $self)
			{
				warn "SocketWorker::fork_receiver() called without a blessed ref, unable to find self-uuid automatically, unable to automatically generate client receipts for $msg_name";
				print_stack_trace();
			}
			else
			{
				$uuid = $self->uuid;
			}
		}

		# wiat_for_start because if we dont, then state_handle->{online} could still
		# be false when we get to that point in the fork if we havn't started yet,
		# causing the fork to exit before the other thread even starts
		$self->wait_for_start if ref $self;

		my $parent_pid = $$;
		
		my $kid = fork();
		die "Fork failed" unless defined($kid);
		if ($kid == 0)
		{

			$0 = "$0 [SocketWorker:$msg_name]";
			trace "SocketWorker: Forked receiver for '$msg_name' in PID $$ as '$0'\n";

			my $queue = $self->rx_listen_queue($$);
			my $receipt_queue = ref $self ? outgoing_queue() : incoming_queue();
			
			# Lock incoming queue so we know that we're not going to duplicate messages
			# between the time we register interest and the time we check for existing
			# incoming messages in the queue
			if(incoming_queue()->lock_file(30) &&
				# Lock the rx_listen_queue for this PID so that the caller of fork_receiver()
				# can use rx_listen_queue() to acquire a lock to know when we're processing inorder
				# to syncronize access to data (e.g. GlobalDB::get())
				$queue->lock_file(30))
			{
				eval
				{
					$self->_rx_register_listener($_, $$) foreach @msg_names;
				};
				error "SocketWorker: Error registering listeners: $@" if $@;
				
				eval
				{
					# Check the general incoming queue for any messages that have come in before we registered interest
					my @list = incoming_queue()->by_key(nxthop => $uuid, type => \@msg_names);
					
					if(@list)
					{
						trace "SocketWorker: Received ", scalar(@list), " messages that arrived prior to registering interest, processing...\n"; 
						$self->_rx_process_messages(\@list, \%msg_subs, $receipt_queue, $uuid);
					}
					
					# Delete from queue if we are called on a class instance (fork_receiver).
					# TODO (true?) The "only" time we would NOT be called on a class instance is if code
					# is running a a hub, in which case, the message router should be the only one deleting
					# messages from the incoming queue
					incoming_queue()->del_batch(\@list) if ref $self;
				};
				error "SocketWorker: Error processing initial messages: $@" if $@;
				
				incoming_queue()->unlock_file;
				$queue->unlock_file;
			}
			else
			{
				error "SocketWorker: Error locking queue at pre-register\n";
			}
			
			while(1)
			{
				if($queue->lock_file)
				{
					my @list = HashNet::MP::MessageQueues->pending_messages($queue);
					#trace "SocketWorker: fork_receiver/$msg_name: Checking for nxthop $uuid, found ".scalar(@list)."\n";
	
					$self->_rx_process_messages(\@list, \%msg_subs, $receipt_queue, $uuid);
					
					$queue->unlock_file;
	
					# See http://perldoc.perl.org/functions/kill.html "If SIGNAL is zero..." for why this works
					unless(kill 0, $parent_pid)
					{
						#trace "SocketWorker: fork_receiver/$msg_name: Parent pid $parent_pid gone away, not listening anymore\n";
						last;
					}
					
					if(ref $self && !$self->state_handle->{online})
					{
						#trace "SocketWorker: fork_receiver/$msg_name: SocketWorker dead or dieing, not waiting anymore\n";
						last;
					}
				}
				else
				{
					#error "SocketWorker: Error locking queue\n";
				}
					
				sleep $speed;
			}

			#trace "SocketWorker: fork_receiver/$msg_name: Exiting fork_receiver() fork\n";
			exit 0;
		}

		# Parent continues here.
		while ((my $k = waitpid(-1, WNOHANG)) > 0)
		{
			# $k is kid pid, or -1 if no such, or 0 if some running none dead
			my $stat = $?;
			debug "Reaped $k stat $stat\n";
		}
# 
# 		if(ref $self)
# 		{
# 			$self->{receiver_forks} ||= [];
# 			push @{$self->{receiver_forks}}, $kid;
# 		}

		return $kid;
	}
	
	sub _rx_process_messages
	{
		my $self = shift;
		my @list = @{ shift || [] };
		my $msg_subs = shift || {};
		my $receipt_queue = shift;
		my $uuid = shift;
	
		if(@list)
		{
			#trace "SocketWorker: _rx_process_messages: Received ".scalar(@list)." messages\n";
			$receipt_queue->begin_batch_update;
			
			foreach my $msg (@list)
			{
				local *@;
				eval
				{
					$msg_subs->{$msg->{type}}->($msg);
				};
				trace "SocketWorker: _rx_process_messages: Error processing msg $msg->{type} {$msg->{uuid}}: $@" if $@;

				# We're cheating the system a bit if we don't have a $self ref -
				# we assume that if no ref $self, we are running on a hub,
				# so we dump the receipt into the *incoming* queue instead
				# of the outgoing queue, and set the nxthop to the *hub's* uuid
				# instead of the uuid on the other end of the socket,
				# so then the local hub picks up the receipt and routes it to
				# all connected clients.
				if($uuid)
				{
					# See note above on 'cheating'
					my $nxthop_uuid = ref $self ? $self->peer_uuid : $uuid;
					
					my $new_env = $self->create_client_receipt($msg, $uuid, $nxthop_uuid);
					
					$receipt_queue->add_row($new_env);
				}
			}

			$receipt_queue->end_batch_update;

			#trace "SocketWorker: _rx_process_messages: Deleting batch: ".Dumper(\@list);

			#$queue->del_batch(\@list) unless $no_del;

			$self->wait_for_send if ref $self;
			#error "SocketWorker: _rx_process_messages: !ref \$self, not waiting for send\n" if !ref $self;

			#print STDERR Dumper $receipt_queue;
		}	
	}
};

1;
