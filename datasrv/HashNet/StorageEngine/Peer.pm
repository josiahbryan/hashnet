#!/usr/bin/perl
use strict;
use warnings;

use common::sense;
use AnyEvent;
use AnyEvent::Impl::Perl; # explicitly include this so it's included whne we buildpacked.pl
use AnyEvent::Loop;

# Per http://modperlbook.org/html/10-2-4-Avoiding-Zombie-Processes.html
# Save us from accumulating a lot of zombie children due to possible use of fork() in push()
#$SIG{CHLD} = 'IGNORE'; #
use POSIX 'WNOHANG';
$SIG{CHLD} = sub { while( waitpid(-1,WNOHANG)>0 ) {  } };

package HashNet::StorageEngine::Peer;
{
	#use base qw/Object::Event/;
	use Storable qw/freeze thaw nstore retrieve/;
	use AnyEvent::HTTP;
#	use LWP::Simple::Post qw/post/;
	use LWP::Simple qw/get/;
	use URI::Escape;
	use Net::Ping;
	use Time::HiRes qw/time sleep alarm/;
	use JSON qw/decode_json encode_json/;
	use POSIX 'WNOHANG';
	use Digest::Perl::MD5 qw/md5_hex/;
	use HashNet::Util::Logging;
	use HashNet::Util::OnDestroy; # exports ondestroy($coderef)
	#use Net::Ping::External qw(ping);
	use Data::Dumper;
	use YAML::Tiny; # for load/save state
	use DBM::Deep; # for our tr_flag datbase
	# Explicitly include here for the sake of buildpacked.pl
	use DBM::Deep::Engine::File;
	
	# This is included ONLY so buildpacked.pl picks it up for use by JSON on some older linux boxen
	use JSON::backportPP;
	
	our $PING_TIMEOUT =  1.75;
	
	my $pinger = Net::Ping->new('tcp');
	$pinger->hires(1);
	
	sub exec_timeout($$)
	{
		my $timeout = shift;
		my $sub = shift;
		#debug "\t exec_timeout: \$timeout=$timeout, sub=$sub\n";
		
		my $timed_out = 0;
		local $@;
		eval
		{
			#debug "\t exec_timeout: in eval, timeout:$timeout\n";
			local $SIG{ALRM} = sub
			{
				#debug "\t exec_timeout: in SIG{ALRM}, dieing 'alarm'...\n";
				$timed_out = 1;
				die "alarm\n"
			};       # NB \n required
			alarm $timeout;

			#debug "\t exec_timeout: alarm set, calling sub\n";
			$sub->(@_); # Pass any additional args given to exec_timout() to the $sub ref
			#debug "\t exec_timeout: sub done, clearing alarm\n";

			alarm 0;
		};
		#debug "\t exec_timeout: outside eval, \$\@='$@', \$timed_out='$timed_out'\n";
		die if $@ && $@ ne "alarm\n";       # propagate errors

		$timed_out = $@ ? 1:0 if !$timed_out;
		#debug "\t \$timed_out flag='$timed_out'\n";
		return $timed_out;
	}
	
	
#public:
	sub new
	{
		my $class = shift;
		my $self = bless {}, $class; #$class->SUPER::new();

		my $engine = shift;
		my $url = shift;
		my $known_as = shift;

		my $uri = URI->new($url);
		if($uri->can('host') && gethostbyname($uri->host))
		{
			my $server = $uri->host;
			my $orig_url = $url;
			my $new_server = sprintf("%d.%d.%d.%d",unpack("C4",gethostbyname($server)));
			
			if($new_server ne $server)
			{
				$uri->host($new_server);
				$url = $uri . '';
				logmsg 'TRACE', "Peer: new(): Changed host from '$server' to ".$uri->host.", new url: '$url', original url: '$orig_url'\n";
			}
		}
		
		$self->{url} = $url;
		$self->{host_down} = 0;
		$self->{known_as} = $known_as;
		$self->{engine} = $engine;
		
		my $db_root = $self->engine->db_root;

		# Can be shared among peers on the same host because we use this to flag the GLOBAL UUID of
		# the transaction - so it doesn't make sens to duplicate global data on the same host
		$self->{tr_cache_file} = $db_root . '.tr_flags';
		logmsg "TRACE", "Peer: Using transaction flag file $self->{tr_cache_file}\n";
		
		$self->_unlock_state(); # cleanup any old locks
		
		$self->load_state();
		$self->update_distance_metric();
		
		return $self;
	}

	sub DESTROY
	{
		my $self = shift;
		#$self->save_state;
		$self->_unlock_state;
	}

	sub state_file
	{
		my $self = shift;
		
		my $url     = $self->{url};
		my $url_md5 = md5_hex($url);
		#logmsg "DEBUG", "Peer: state_file(): Using url '$url', md5: $url_md5\n";

		# engine is undef when called in DESTROY, above
		return $self->{_cached_state_file_name} if !$self->engine;
		#return $self->{_cached_state_file_name} if $self->{_cached_state_file_name};
		
		my $root = $self->engine->db_root;
		$root .= '/' if $root !~ /\/$/;
		
		# TODO is this name going to cause problems? Does it need to be more host-specific?
		return $self->{_cached_state_file_name} = $root . '.peer-'.$url_md5.'.state';
	}

	sub load_state
	{
		my $self = shift;
		my $file = $self->state_file;
		
		my $state = {};
#		debug "Peer: Loading state file '$file' in pid $$\n";
		{
			local $@;
			eval
			{
				#$state = retrieve($file) if -f $file && (stat($file))[7] > 0;
				
				#system("cat $file");
				
				if(-f $file && (stat($file))[7] > 0)
				{
					#$state = YAML::Tiny::LoadFile($file);
					$state = retrieve($file);
				}
				else
				{
					die "File $file does not exist or is empty";
				}
			};
			
			logmsg "DEBUG", "Peer: Error loading state from '$file': $@" if $@;
		}

		$self->{version}	 = $state->{version};
		$self->{known_as}	 = $state->{known_as};
		$self->{node_info}	 = $state->{node_info};
		$self->{host_down}	 = $state->{host_down};
		$self->{last_tx_sent}	 = $state->{last_tx_sent};
		$self->{last_tx_recd}	 = $state->{last_tx_recd};
		$self->{distance_metric} = $state->{distance_metric};
		$self->{last_seen}	 = $state->{last_seen};
		
		#logmsg "DEBUG", "Peer: load_state(): $file: node_info: ".Dumper($state->{node_info});
		
		$state->{last_tx_sent} = -1 if ! defined $state->{last_tx_sent};
		$state->{last_tx_recd} = -1 if ! defined $state->{last_tx_recd};
		
		#trace "Peer: Load peer state:  $self->{url} \t $self->{last_tx_recd} (+in)\n";
	}

	sub _lock_state
	{
		my $self = shift;
		#debug "Peer: _lock_state():    ",$self->url," (...)  [$$]\n"; #: ", $self->state_file,"\n";
		if(!NetMon::Util::lock_file($self->state_file, 3)) # 2nd arg max sec to wait
		{
			#die "Can't lock ",$self->state_file;
			return 0;
		}
		
		#debug "Peer: _lock_state():    ",$self->url," (+)    [$$]\n"; #: ", $self->state_file,"\n";
		return 1;
		
	}

	sub _unlock_state
	{
		my $self = shift;
		#debug "Peer: _unlock_state():  ",$self->url," (-)    [$$]\n"; #: ", $self->state_file,"\n";
		NetMon::Util::unlock_file($self->state_file);
		
	}
	
	# Determine if the state is dirty by checking the mtime AND the size -
	# if either changed, assume state was updated by another process.
	sub _cache_dirty
	{
		my $self = shift;
		my $cache = $self->state_file;
		if(-f $cache && (
			(stat($cache))[9]  != $self->{cache_mtime} || 
			(stat(_))[7]       != $self->{cache_size}
		))
		{
			return 1;
		}
		
		return 0;
	}
	
	sub update_begin
	{
		my $self = shift;
		my $cache = $self->state_file;
		
		if(!$self->{_locked})
		{
			if(!$self->_lock_state)
			{
				return 0;
			}
		}
		
		$self->{_locked} = 1;
		
		if($self->_cache_dirty)
		{
			$self->load_state;
			$self->{updated} = 1;
		}
		
		# Returns undef if in void context
		if(defined wantarray)
		{
			return ondestroy sub { $self->update_end };
		}
		
		return 1;
	}
	
	sub load_changes
	{
		my $self = shift;
		
		if($self->_cache_dirty)
		{
			$self->load_state;
			
			my $cache = $self->state_file;
			
			# Store our cache size/time in memory, so if another fork changes
			# the cache, sync_in() will notice the change and reload the cache
			$self->{cache_mtime} = (stat($cache))[9];
			$self->{cache_size}  = (stat(_))[7];
			
			return 1;
		}
		
		return 0;
	}
	
	sub update_end
	{
		my $self = shift;
		my $cache = $self->state_file;
		
		my $changed = shift;
		$changed = 1 if !defined $changed;
		
		if($changed)
		{
			$self->save_state;
			
			# Store our cache size/time in memory, so if another fork changes
			# the cache, sync_in() will notice the change and reload the cache
			$self->{cache_mtime} = (stat($cache))[9];
			$self->{cache_size}  = (stat(_))[7];
		}
		
		$self->{updated} = 0;
		
		# Release lock on cache
		$self->_unlock_state;
		$self->{_locked} = 0;
	}

	sub save_state
	{
		my $self = shift;
		my $file = $self->state_file;

		my $state =
		{
			version		=> $self->version,
			known_as	=> $self->known_as,
			node_info	=> $self->node_info,
			host_down	=> $self->host_down,
			last_tx_sent	=> $self->last_tx_sent,
			last_tx_recd	=> $self->last_tx_recd,
			last_seen	=> $self->last_seen,
			distance_metric => $self->distance_metric,
		};
		
		#trace "Peer: Save peer state:  $self->{url} \t $state->{last_tx_recd} (-out) [-> $file]\n";
		#print_stack_trace();
		
		#logmsg "DEBUG", "Peer: save_state(): $file: node_info: ".Dumper($state->{node_info});

		nstore($state, $file);
		#YAML::Tiny::DumpFile($file, $state);
		#system("cat $file");
	}

	sub version	{ shift->{version} }
	sub url		{ shift->{url} }
	sub host_down	{ shift->{host_down} }
	sub known_as	{ shift->{known_as} }
	sub engine	{ shift->{engine} }
	sub node_info	{ shift->{node_info} || {} }
	sub last_seen   { shift->{last_seen} }
	
	sub node_uuid   { shift->node_info->{uuid} }
	sub node_name   { shift->node_info->{name} }
	
	sub last_tx_recd { shift->{last_tx_recd} }
	sub last_tx_sent { shift->{last_tx_sent} }
	
	sub poll_only   { shift->{poll_only} }
	sub cur_tx_id   { shift->{cur_tx_id} }

# 	# Use settors for last_tx_* so we can save_state immediately
# 	sub set_last_tx_recd
# 	{
# 		my $self = shift;
# 		my $tx = shift;
# 		$self->{last_tx_recd} = $tx;
# 		$self->save_state;
# 	}
# 
# 	sub set_last_tx_sent
# 	{
# 		my $self = shift;
# 		my $tx = shift;
# 		$self->{last_tx_sent} = $tx;
# 		$self->save_state;
# 	}
	
	sub update_distance_metric
	{
		my $self = shift;
		
		$self->update_begin();
		$self->{distance_metric} = $self->calc_distance_metric();
		
		if(!$self->{host_down})
		{
			my $date = `date`;
			$date =~ s/[\r\n]//g;
			$self->{last_seen} = $date;
		}
		 
		$self->update_end();
	}
	
	# put_peer_stats was part of update_distance_metric
	# But we don't need a lock around put_peer_stats() since it doesn update
	# the state of the peer
	sub put_peer_stats
	{
		my $self = shift;
		my $my_uuid = HashNet::StorageEngine::PeerServer->node_info->{uuid};
		if(!$my_uuid)
		{
			logmsg 'WARN', "Peer: Could not find the node_info UUID for this computer, something went wrong. Unable data in engine.\n";
			return;
		}
		
		my $other_uuid = $self->node_uuid;
		if(!$other_uuid)
		{ 
			logmsg 'WARN', "Peer: No node_info received from remote peer $self->{url}, unable to store data in engine.\n"
				unless $self->{host_down} && $self->{warned_about_node_uuid} ++;
				# Don't over-warn about down hosts
			return;
		}

		#debug "Peer: Updating database with peer stats for $self->{url}\n"
		#	unless $self->{host_down};
		
		my $my_root = '/global/nodes/'.$my_uuid.'/peers';
		my $key_root = $my_root.'/'.$other_uuid;

		my $in_batch = $self->engine->in_batch_update;
		
		$self->engine->begin_batch_update() if ! $in_batch;
		
		my $flag = $self->host_down ? 1:0;
		my $cur_flag = $self->engine->get("$key_root/host_down") || 0;
		$cur_flag = $cur_flag eq "" ? 0 : int($cur_flag); # all this is just to avoid warnings
		$self->engine->put("$key_root/host_down", $flag)
			if $cur_flag != $flag;
		#logmsg "DEBUG", "Peer: put_peer_states(): cur_flag:'$cur_flag', flag:'$flag'\n";
			
		$self->engine->put("$key_root/latency", $self->distance_metric)
			if ($self->engine->get("$key_root/latency")||0) != ($self->distance_metric||0);

		$self->engine->put("$key_root/known_as", $self->known_as)
			if ($self->engine->get("$key_root/known_as")||'') ne ($self->known_as || '');
			
		$self->engine->put("$key_root/last_tx_sent", $self->last_tx_sent)
			if ($self->engine->get("$key_root/last_tx_sent")||0) != ($self->last_tx_sent||0);

		$self->engine->put("$key_root/last_tx_recd", $self->last_tx_recd)
			if ($self->engine->get("$key_root/last_tx_recd")||0) != ($self->last_tx_recd||0);

		$self->engine->put("$key_root/last_seen", $self->last_seen)
			if !$self->host_down;

		# Calls end_batch_update automatically, only if not already in a batch update by external caller
		$self->engine->end_batch_update if !$in_batch;

		#$self->engine->put("$key_root/latency", $self->distance_metric);
	}

	my $DEBUG = 1;
	# Generic subroutine to handle pinging using the system() function. Generally,
	# UNIX-like systems return 0 on a successful ping and something else on
	# failure. If the return value of running $command is equal to the value
	# specified as $success, the ping succeeds. Otherwise, it fails.
	sub _ping_system {
		my ($command,   # The ping command to run
		$success,   # What value the system ping command returns on success
		) = @_;
		my $devnull = "/dev/null";
		$command .= " 1>$devnull 2>$devnull";
		print "#$command\n" if $DEBUG;
		my $exit_status = system($command) >> 8;
		print "## $exit_status == $success;\n" if $DEBUG;
		return 1 if $exit_status == $success;
		return 0;
	}
	# Debian 2.2 OK, RedHat 6.2 OK
	# -s size option available to superuser... FIXME?
	sub _ping_linux {
		my %args = @_;
		my $command;
		#for next version
		if (-e '/etc/redhat-release' || -e '/etc/SuSE-release') {
		$command = "ping -c $args{count} -s $args{size} $args{host}";
		} else {
		$command = "ping -c $args{count} $args{host}";
		}
		return _ping_system($command, 0);
	}


	sub extern_ping
	{
		my ($host, $timeout) = @_;
		my $ts = time;
		my $result;
		my $timeout_flag = exec_timeout $timeout, sub {
			$result = _ping_linux(hostname => $host);
		};
		my $te = time;
		my $td = $te - $ts;
		#debug "Peer: extern_ping($host): \$result='$result', td: $td\n";
		debug "Peer: extern_ping($host): \$result='$result', timeout_flag?'$timeout_flag', timeout:$timeout, td:$td\n";
		return $timeout_flag ? 0 : $result;
	}

	sub is_valid_peer
	{
		shift if ref($_[0]) eq __PACKAGE__ || $_[0] eq __PACKAGE__;
		
		my $url  = shift || '';

		my $uri  = URI->new($url)->canonical;
		if(!$uri->can('host'))
		{
			info "Peer: is_valid_peer($url): Unable to check url '$url' - URI module can't parse it.\n";
			return 0;
		}

		my $host = $uri->host;

# 		#if(!$pinger->ping($host, $PING_TIMEOUT))
# 		if(!extern_ping($host, $PING_TIMEOUT))
# 		{
# 			info "Peer: is_valid_peer($url): Not adding peer '$url' because cannot ping $host within $PING_TIMEOUT seconds\n";
# 			#die "Peer: is_valid_peer($url): Not adding peer '$url' because cannot ping $host within $PING_TIMEOUT seconds";
# 			#die "Test Done";
# 			return 0;
# 		}

		my $ver = $HashNet::StorageEngine::VERSION;
		my $ver_url = $uri . '/ver?upgrade_check=' . $ver;

		my $json;

		my $timed_out  = exec_timeout 3.0, sub { $json = get($ver_url); };

		if($timed_out)
		{
			info "Peer: is_valid_peer($url): Timed out while getting $ver_url, not a valid peer URL\n";
			return 0;
		}

		if(!$json)
		{
			info "Peer: is_valid_peer($url): Empty string from $ver_url, not a valid peer URL\n";
			return 0;
		}

		my $data = decode_json($json);
		return wantarray ? $data->{node_info}->{uuid} : $data->{node_info};
	}

	sub distance_metric { shift->{distance_metric} }
	sub calc_distance_metric
	{
		my $self = shift;
		my $url  = $self->url;
		my $uri  = URI->new($url)->canonical;
		my $host = $uri->can('host') ? $uri->host : undef;
		
		my $ver = $HashNet::StorageEngine::VERSION;

		# Assume host is up unless we find otherwise below
		#$self->{host_down} = 0;
		
		if(HashNet::StorageEngine::PeerServer->is_this_peer($url))
		{
			info "Peer: calc_distance_metric($url): '$url' is this peer\n";
			$self->{version} = $ver;
			return 0;
		}
		
		$pinger->service_check(1);
		$pinger->port_number($uri->port);
		
		if(!$pinger->ping($host, $PING_TIMEOUT))
		{
			logmsg "INFO", "Peer: calc_distance_metric($url): Host not responding to pings, marking as bad.\n";
			$self->{host_down} = 1;
			return undef;
		}
		
		my $ver_url = $self->url . '/ver?upgrade_check=' . $ver;
		
		# We only need to include peer_url to let the peer know log version software
		# we're running - however, that's irrelevant for clients
		if(HashNet::StorageEngine::PeerServer->active_server)
		{
			$ver_url .= '&peer_url=' . ($self->{known_as} || '');
		}
		
		my $json;
		my $start_time = time();
		
		my $timed_out  = exec_timeout 3.0, sub { $json = get($ver_url); };
		
		my $end_time   = time();
		my $latency    = $end_time - $start_time;
		
		if($timed_out)
		{
			info "Peer: calc_distance_metric($url): Timed out while updating metrics, marking down\n";
			$self->{host_down} = 1;
			return undef;
		}

		if(!$json)
		{
			logmsg "WARN", "Peer: calc_distance_metric($url): Empty string from $ver_url, marking down\n";
			$self->{host_down} = 1;
			return undef;
		}
		
		my $data = decode_json($json);
		$self->{version}   = $data->{version};
		$self->{cur_tx_id} = $data->{cur_tx_id};
		#$self->{ver_string} = $data->{ver_string};
		
		# Debugging of empty node_info discoverd thru test/progate.t
		my @keys = keys %{$data->{node_info} || {}};
		if(!@keys)
		{
			logmsg "WARN", "Peer: calc_distance_metric(): No node_info received in data blob, Dumper of data: ", Dumper($data);
		}
		else
		{
			$self->{node_info} = $data->{node_info};
		}
		
		
		if($self->{host_down})
		{
			info "Peer: calc_distance_metric(): '$url' was down, but now seems to be back up, adjusting state.\n";
			$self->{host_down} = 0;
		}
		
		#trace "Peer: calc_distance_metric($url): latency: $latency seconds\n"; # ($start_time / $end_time)\n";
		
		return $latency;
	}
	
	sub tr_flag_db
	{
		my $self = shift;

		if(!$self->{tr_flag_db} ||
		  # Re-create the DBM::Deep object when we change PIDs -
		  # e.g. when someone forks a process that we are in.
		  # I learned the hard way (via multiple unexplainable errors)
		  # that DBM::Deep does NOT like existing before forks and used
		  # in child procs. (Ref: http://stackoverflow.com/questions/11368807/dbmdeep-unexplained-errors)
		  ($self->{_tr_flag_db_pid}||0) != $$)
		{
			$self->{tr_flag_db} = DBM::Deep->new($self->{tr_cache_file});
# 				file => $self->{tr_cache_file},
# 				locking   => 1, # enabled by default, just here to remind me
# 				autoflush => 1, # enabled by default, just here to remind me
# 				#type => DBM::Deep->TYPE_ARRAY
# 			);
			warn "Error opening $self->{tr_cache_file}: $@ $!" if ($@ || $!) && !$self->{tr_flag_db};
			$self->{_tr_flag_db_pid} = $$;
		}
		return $self->{tr_flag_db};
	}


	sub poll
	{
		my $self = shift;
		my $url = $self->{url};
		$url =~ s/\/$//g;
		$url .= '/tr_poll';

		$self->load_changes;
		
		my $my_uuid = HashNet::StorageEngine::PeerServer->node_info->{uuid};
		my $last_tx = $self->{last_tx_recd};

		$url .= '?last_tx='.$last_tx;
		$url .= '&node_uuid='.$my_uuid;

		my $json;

		trace "Peer: poll(): Polling peer at url '$url'\n";

		# Give a VERY generous timeout because if we are very far behind, it
		# may take the peer a long time to compile the transaction
		#my $timed_out  = exec_timeout 60.0 * 10, sub { $json = get($url); };
		
		# 10 min was too generous....
		my $timed_out  = exec_timeout 10.0, sub { $json = get($url); };
		

		if($timed_out)
		{
			info "Peer: poll(): Timed out while getting $url, not a valid peer URL\n";
			$self->update_begin;
			$self->{host_down} = 1;
			$self->update_end;
			return 0;
		}

		if(!$json)
		{
			info "Peer: poll(): Empty string from $url, not a valid peer URL\n";
			$self->update_begin;
			$self->{host_down} = 1;
			$self->update_end;
			return 0;
		}

		my $data;
		undef $@;
		
		eval { $data = decode_json($json); };
		
		if($@)
		{
			info "Peer: poll(): Invalid JSON received: $@";
			$self->update_begin;
			$self->{host_down} = 1;
			$self->update_end;
			return 0;
		}

		$self->update_begin;
		if($self->{host_down})
		{
			info "Peer: poll(): Peer was down, marking up\n";
			$self->{host_down} = 0;
		}
		
		if(defined $data->{cur_tx_id})
		{
			$self->{last_tx_recd} = $data->{cur_tx_id};
			logmsg "TRACE", "Peer: poll(): Updated cur_tx_id to $data->{cur_tx_id}\n";
		}
		else
		{
			logmsg "TRACE", "Peer: poll(): No cur_tx_id received in data\n";
		}
		$self->update_end;
		
		# Patch old data from previous versions
		if(ref $data->{batch} eq 'HASH')
		{
			$data->{batch} = [$data->{batch}];
		}
		
		my @batch = @{$data->{batch} || []};
			
		if(!@batch)
		{
			#logmsg "TRACE", "Peer: poll(): JSON: $json\n";
			logmsg "TRACE", "Peer: poll(): Valid empty batch received, nothing done\n";
		}
		else
		{
			logmsg "TRACE", "Peer: poll(): Received \$data: ", Dumper $data;

			foreach my $data (@batch)
			{
				my $tr = HashNet::StorageEngine::TransactionRecord->from_hash($data);

				$self->tr_flag_db->lock_exclusive;
	
				# Prevent recusrive updates of this $tr
				if($self->tr_flag_db->{$tr->uuid} ||
				   $tr->has_been_here) # it checks internal {route_hist} against our uuid
				{
					$self->tr_flag_db->unlock;
					logmsg "TRACE", "Peer: poll(): Already seen ", $tr->uuid, " - not processing\n";
				}
				else
				{
					$self->tr_flag_db->{$tr->uuid} = 1;
					$self->tr_flag_db->unlock;
	
					# If the tr is valid...
					if(defined $tr->key)
					{
						#logmsg "TRACE", "Peer: poll(): ", $tr->key, " => ", (ref($tr->data) ? Dumper($tr->data) : ($tr->data || '')), ($url ? " (from $url)" :""). "\n"
						#	unless $tr->key =~ /^\/global\/nodes\//;
	
						#logmsg "TRACE", "Peer: poll(): Received ", $tr->key, ", tr UUID $tr->{uuid}", ($url ? " (from $url)" :""). "\n".Dumper($tr);
	
						my $eng = $self->engine;
						
						# We dont use eng->put() here because it constructs a new tr
						if($tr->type eq 'TYPE_WRITE_BATCH')
						{
							$eng->_put_local_batch($tr->data);
						}
						else
						{
							$eng->_put_local($tr->key, $tr->data, $tr->timestamp);
						}
	
						$eng->_push_tr($tr); #, $peer_url); # peer_url is the url of the peer to skip when using it out to peers
					}
				}
			}
		}
	}
	
	sub push
	{
		my $self = shift;
		my $tr_batch = shift;
		my $end_tx_id = shift || -1;
		
		if(ref $tr_batch eq 'HASH')
		{
			$tr_batch = [%{$tr_batch || {}}];
		}
		elsif(ref $tr_batch eq 'HashNet::StorageEngine::TransactionRecord')
		{
			$tr_batch = [$tr_batch->to_hash];
			
			# We're pushing via 'freeze', so we don't need to go to_hash
			#$tr_batch = [$tr_batch]; #->to_hash];
		}

		my @uuids_expected;
		push @uuids_expected, $_->{uuid} foreach @{$tr_batch || []};
		
		my $url = $self->{url};
		$url =~ s/\/$//g;
		$url .= '/tr_push';

# 		if($self->host_down)
# 		{
# 			trace "Peer: push($url): Host down, not pushing\n";
# 			return 0;
# 		}

		#print_stack_trace();
		my $post_url = $url;
		my $data =
		{
			format    => 'bytes',
			#batch     => HashNet::StorageEngine::TransactionRecord::_clean_ref($tr_batch),
			cur_tx_id => $end_tx_id,
			node_uuid => HashNet::StorageEngine::PeerServer->node_info->{uuid}, #$self->node_uuid,
		};
		
		#debug "Peer: push($url): Data dump: ", Dumper($data);
		#debug "Peer: push($url): tr_batch dump: ", Dumper($tr_batch);
		
		my $json = encode_json($data);
		my $payload =
		{
			data	=> $json,
			
			# This will post in the content body of the HTTP POST request
			#Content	=> freeze(HashNet::StorageEngine::TransactionRecord::_clean_ref($tr_batch)),
		};
		
		my $Content = freeze(HashNet::StorageEngine::TransactionRecord::_clean_ref($tr_batch)),
		$post_url .= '?data='.uri_escape($json);
		
		#debug "Peer: push(): \$post_url: $post_url\n";


		# Testing 10k put()'s in a loop gave an average time of 20ms per put() call to a
		# peer running on localhost. Additionally, anecdotal observations of peers running
		# over SSH tunnels this weekend showed latencies for /db/ver requests anywhere from
		# 0.05 to 1.5 seconds - so this timeout should be more than enough for "normal"
		# operations.
		my $timeout = 999.0;

		my $json = undef;

		if(!$self->{ua})
		{
			$self->{ua} = LWP::UserAgent->new;
			$self->{ua}->timeout(10);
			$self->{ua}->env_proxy;
		}

		my $ua = $self->{ua};

		#trace "Peer: push($url): Starting push, timeout:$timeout\n";
		my $start = time();
		#trace "Peer: push(): post_ur:$post_url, payload:".Dumper($payload);
		#my $timed_out = exec_timeout $timeout, sub{ $result = get($final_url) };
		my $timed_out = exec_timeout $timeout, sub
		{
			#my $response = $ua->post($post_url, $payload);
			my $response = $ua->post($post_url, Content => $Content);

			if ($response->is_success)
			{
				$json = $response->decoded_content;  # or whatever
			}
			else
			{
				debug "Peer: push($post_url): Error while posting: ", $response->status_line, "\n";
				#die $response->status_line;
			}
		};

		my $end = time();
		my $diff = $end - $start;
		#trace "Peer: push($url): Done push, timed_out?'$timed_out', diff:'$diff'\n";

		if($timed_out)
		{
			debug "Peer: push($url): Timeout while trying to push transaction to $post_url";
			return 0;
		}

		#trace "Peer: push($url): Data rx'd: [$result]\n";
		my $rx_uuid_list;
		if(!$json)
		{
			debug "Peer: push($url): No data received from transaction push\n";
			return 0;
		}

		my $data;
		{
			local $@;
			eval
			{
				$rx_uuid_list = decode_json($json);
			};

			if($@)
			{
				logmsg "TRACE", "Peer: push($url): Error parsing JSON from server: $@, data: $json\n";
				return 0;
			}
		}

		my %uuids_rxd;
		eval
		{
			%uuids_rxd = map { $_ =>  1 } @{$rx_uuid_list || []};
		};
		if($@)
		{
			logmsg "TRACE", "Peer: push($url): Error checking rx'd uuid list: $@\n";
		}

		foreach my $uuid (@uuids_expected)
		{
			if(!defined $uuids_rxd{$uuid})
			{
				debug "Peer: push($url): Error pushing: uuid $uuid missing from results returned from server\n";
				return 0;
			}
		}

		return 1;
	}
	
# 	sub DESTROY
# 	{
# 		my $self = shift;
# 		my @cvs = @{$self->{cvars} || []};
# 		
# 		foreach my $cv (@cvs)
# 		{
# 			next if !$cv;
# 			
# 			trace "Peer: DESTROY: Waiting on cv '$cv'\n";
# 			$cv->recv;
# 		}
# 	}

	sub pull
	{
		my $self = shift;
		my $key = shift;
		my $req_uuid = shift;
		
		my $url = $self->{url};
		$url =~ s/\/$//g;
		$url .= '/get';

		if($self->host_down)
		{
			trace "Peer: pull($url): Host down, not pulling\n";
			return;
		}

		# NOTE $key should already have been sanatized by StorageEngine
		$url .= '?key=' . $key . '&uuid=' . $req_uuid;
		my $r;

		my $timed_out = exec_timeout 6.0, sub { $r = get($url) };
		
		# TODO Test datatypes other than text for $r
		
		trace "Peer: pull($url): Timed out while pulling from $url\n" if $timed_out;

		return undef if $timed_out;
		

		# TODO Offer a callback version of 'pull()' with http_get from AnyEvent::HTTP
		return $r;
	}

	# Peers can be either push or pull
	# Push replicants are public/exposed - can be reached on demand
	# Pull replicants must query a push replicant for updated or push updates to it
};


1;