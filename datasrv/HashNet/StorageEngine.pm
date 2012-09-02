#!/usr/bin/perl
use strict;
use warnings;

package HashNet::Cipher;
{
	use Crypt::Blowfish_PP;
	use Crypt::CBC;

	# TODO Make key more secure, user configurable
	my $cipher = Crypt::CBC->new( -key    => 'HashNet', #`cat key`,
				      -cipher => 'Blowfish_PP'
				);

	sub cipher { return $cipher; }
};

package HashNet::StorageEngine;
{
	# Storage Engine has to do two things:
	# - Take in transactions, write to disk (and do the opposite)
	# - Make sure transactions get replicated

	# Transactions:
	#	- Function calls
	#	- Internally, wraps non-query calls in a TransactionRecord that can be replayed (and replicated, and logged, ...)

	# Replication:
	#	- Keeps list of Replicants (HashNet::StorageEngine::Peer) objects that can receive transactions
	#	- If receive query for keys that dont exist, check Replicants
	# 	- Replicants objects should wrap the network comms so they're transparent to StorageEngine
	#		- Consider using Object::Event
	
	use base qw/Object::Event/;
	use Storable qw/freeze thaw store retrieve/;
	use File::Path qw/mkpath/;
	use Data::Dumper;
	use Net::Ping;
	use Time::HiRes qw/time sleep/;
	use Cwd qw/abs_path/;
	use DBM::Deep;
	# Explicitly include here for the sake of buildpacked.pl
	use DBM::Deep::Engine::File;
	
	use HashNet::StorageEngine::PeerDiscovery;
	use HashNet::StorageEngine::PeerServer;
	use HashNet::StorageEngine::Peer;
	use HashNet::StorageEngine::TransactionRecord;
	use HashNet::Util::Logging;

	use UUID::Generator::PurePerl;

	my $ug = UUID::Generator::PurePerl->new();

	our $VERSION = 0.0265;
	
	our $PING_TIMEOUT =  1.75;
	
	my $pinger = Net::Ping->new('tcp');
	$pinger->hires(1);
	
	our $PEERS_CONFIG_FILE = ['/etc/dengpeers.cfg','/root/peers.cfg','/opt/hashnet/datasrv/peers.cfg'];
	our $DEFAULT_DB_ROOT   = '/var/lib/hashnet/db';
	our $DEFAULT_DB_TXLOG  = '.txlog';
#public:
	sub new
	{
		my $class = shift;
		my $self = $class->SUPER::new();

		my %args = @_;

		$PEERS_CONFIG_FILE = $args{config} if $args{config};

		if(ref($PEERS_CONFIG_FILE) eq 'ARRAY')
		{
			my @files = @$PEERS_CONFIG_FILE;
			my $found = 0;
			foreach my $file (@files)
			{
				if(-f $file)
				{
					print STDERR "[INFO] StorageEngine: Using peers config file '$file'\n";
					$PEERS_CONFIG_FILE = $file;
					$found = 1;
					last;
				}
			}
			
			if(!$found)
			{
				my $file = shift @$PEERS_CONFIG_FILE;
				print STDERR "[INFO] StorageEngine: No config file found, using default location '$file'\n";
				$PEERS_CONFIG_FILE = $file;
			}
		}
		else
		{
			#die Dumper $PEERS_CONFIG_FILE;
		}
		
		# Create our database root
		$self->{db_root} = $args{db_root} || $DEFAULT_DB_ROOT;
		mkpath($self->{db_root}) if !-d $self->{db_root};
		
		# Setup our transaction log storage
		my $txlog_file = $args{tx_file} || $DEFAULT_DB_TXLOG;
		my $txlog_abs_file;
		if($txlog_file !~ /^\//)
		{
			$txlog_abs_file = abs_path($self->{db_root} . $txlog_file);
		}
		else
		{
			$txlog_abs_file = abs_path($txlog_file);
		}
		$self->{tx_file} = $txlog_abs_file;

		print STDERR "[DEBUG] StorageEngine: Using '$txlog_abs_file' as transaction log\n";
		# Only create {tx_db} on first use to avoid having it created before a fork if possible

		my @peers;
		#push @peers, qw{http://bryanhq.homelinux.com:8031/db};
		#push @peers, qw{http://dts.homelinux.com/hashnet/db};
		#push @peers, qw{http://10.10.9.90:8031/db};
		#push @peers, qw{http://10.1.5.168:8031/db};

		#print STDERR "[DEBUG] StorageEngine: new: mark1\n";
		
		@peers = $self->load_peers();

		#print STDERR "[DEBUG] StorageEngine: new: mark2\n";
		
		@peers = HashNet::StorageEngine::PeerDiscovery->discover_peers() 
			if ! @peers;
	
		my @peer_tmp;
		foreach my $url (@peers)
		{
			my $known_as = undef;
			($url, $known_as) = split /\s+/, $url if $url =~ /\s/;
			
			my $peer = HashNet::StorageEngine::Peer->new($self, $url, $known_as);
			
			#print STDERR "[DEBUG] StorageEngine: Loaded peer $url", ($known_as ? ", known as '$known_as' to remote peer" : ", no known as stored, will auto-discover"), ".\n";
			
			push @peer_tmp, $peer;
		}
		$self->{peers} = \@peer_tmp;
	
		$self->_sort_peers();
		$self->_list_peers();
		
		$self->save_peers();
		
		#die Dumper $self->{peers};

		#print STDERR "[DEBUG] StorageEngine: new: mark3\n";
		
		return $self;
	};

	sub db_root { shift->{db_root} }
	
	sub tx_db
	{
		my $self = shift;
		
		if(!$self->{tx_db} ||
		  # Re-create the DBM::Deep object when we change PIDs -
		  # e.g. when someone forks a process that we are in.
		  # I learned the hard way (via multiple unexplainable errors)
		  # that DBM::Deep does NOT like existing before forks and used
		  # in child procs. (Ref: http://stackoverflow.com/questions/11368807/dbmdeep-unexplained-errors)
		  ($self->{_tx_db_pid}||0) != $$)
		{
			$self->{tx_db} = DBM::Deep->new(
				file => $self->{tx_file},
				locking   => 1, # enabled by default, just here to remind me
				autoflush => 1, # enabled by default, just here to remind me
				type => DBM::Deep->TYPE_ARRAY
			);
			$self->{_tx_db_pid} = $$;
		}
		return $self->{tx_db};
	}
	
	sub load_peers
	{
		my $self = shift;
		my $file = shift || $PEERS_CONFIG_FILE;
		
		my @list;
		return @list if !-f $file;
		
		open(F, "<$file") || die "Cannot read $file: $!";
		push @list, $_ while $_ = <F>;
		close(F);
		
		# Trim whitespace and EOLs
		s/(^\s+|\s+$|[\r\n])//g foreach @list;
		
		return @list;
	}
	
	sub save_peers
	{
		my $self = shift;
		my $file = shift || $PEERS_CONFIG_FILE;
		
		my @list = @{ $self->peers };
		return if !@list;
		
		open(F, ">$file") || die "Cannot write $file: $!";
		print F $_->{url}, " ", ($_->{known_as} || ''), "\n" foreach @list;
		close(F);
		
		return @list;
	}
	
	sub add_peer
	{
		# TODO I've seen 127.0.0.1 wind up in peers.cfg (even though the LAN IP is also there) - so eventually we need to trace and figure out where that's coming from
		# But for now, it's not causing any problems, thanks to other checks and stops in the code
	
		my $self = shift;
		my $url = shift;
		my $bulk_mode = shift || 0;

		foreach my $p (@{ $self->peers })
		{
			if($p->{url} eq $url)
			{
				#print STDERR "[WARN]  StorageEngine: add_peer(): Not adding peer '$url' it's already in our list of peers.\n";
				return -1; 
			}
		}
		
		my $peer = HashNet::StorageEngine::Peer->new($self, $url);
		
		my $uri  = URI->new($url)->canonical;
		my $host = $uri->host;
		
		if(!$pinger->ping($host, $PING_TIMEOUT))
		{
			print STDERR "[WARN]  StorageEngine: add_peer(): Not adding peer '$url' because cannot ping $host within $PING_TIMEOUT seconds\n";
			return 0; 
		}
		
		push @{ $self->peers }, $peer;

		if(!$bulk_mode)
		{
			$self->_sort_peers();

			$self->save_peers();
		}
		
		return 1;
	}
	
	sub peer
	{
		# Find peer for given url
		my $self = shift;
		my $url = shift;
		my @peer_tmp = @{ $self->peers };
		foreach my $peer (@peer_tmp)
		{
			return $peer if $peer->url eq $url;
		}
		return undef;
	}

	sub _sort_peers
	{
		my $self = shift;
		
		my @peer_tmp = @{ $self->peers };
		@peer_tmp = sort { ($a->distance_metric||999) <=> ($b->distance_metric||999) } @peer_tmp;
		$self->{peers} = \@peer_tmp;
	}
	
	sub _list_peers
	{
		my $self = shift;
		my $num = 0;
		my @peer_tmp = @{ $self->peers };
		foreach my $peer (@peer_tmp)
		{
			next if $peer->host_down;
			
			$num ++;
			print "[TRACE] StorageEngine: Peer $num: $peer->{url} ($peer->{distance_metric} sec)\n";
		}
		
	}
	
	sub peers
	{
		my $self = shift;
		$self->{peers} ||= [];
		return $self->{peers};
	}
		
	
	sub put
	{
		my $t = shift;
		my $key = shift;
		my $val = shift;

		$key = sanatize_key($key);

		if(!$key && $@)
		{
			warn "[ERROR] StorageEngine: put(): $@";
			return undef;
		}

		$key = '/'.$key if $key !~ /^\//;

		$t->_put_peers($key, $val);
		$t->_put_local($key, $val);
	}
		
	sub _put_peers
	{
		my $t = shift;
		my $key = shift;
		my $val = shift;
		
		my $tr = HashNet::StorageEngine::TransactionRecord->new('MODE_KV', $key, $val, 'TYPE_WRITE');
		$tr->update_route_history;
		
		$t->_push_tr($tr);
	}
	
	sub _push_tr
	{
		my $t = shift;
		my $tr = shift;

		# Used by PeerServer to prevent "tag backs"
		my $skip_peer_url = shift;

		# Deref here in the hope of some small performance gain
		# by not having to deref two more times below
		my @peers = @{$t->{peers} || []};

		my $peer_server = HashNet::StorageEngine::PeerServer->active_server;

		# See comments below on why !$peer_server
# 		#if(!$peer_server)
# 		{
# 			# Lock state so the last_tx_sent doesn't get out of sync between processes
# 			foreach my $p (@peers)
# 			{
# 				if(defined $peer_server &&
# 				   $peer_server->is_this_peer($p->url))
# 				{
# 					#logmsg "TRACE", "StorageEngine: _push_tr(): Not pushing to ", $p->url, " - it's our local peer and local is active.\n";
# 					next;
# 				}
# 				
# 				# Lock the state file (and load it if changed in another thread)
# 				# to ensure that when we set the {last_tx_sent} it will be the correct
# 				# id and will not change between the time we generate {rel_id}
# 				# and the time we call save_state()
# 				$p->update_begin();
# 			}
# 		}
		
		# Lock the tx db so that we know the length() is not changed between the
		# time we call push() and the time we call length() by another process.
		my $db = $t->tx_db;
		$db->lock_exclusive();
		{
			# rel_id is relative to this machine - each peer that getts this transaction
			# will give it a new relative id - so that *it's* peers can know what ID
			# to reference for playback if needed
			$tr->{rel_id} = $db->length();

			# Let the DB worry about serialization (instead of using to_json)
			$db->push($tr->to_hash);

			debug "StorageEngine: _push_tr(): $tr->{uuid}: relid: $tr->{rel_id}\n";
		}
		$db->unlock();
		
		
		# We're only going to push transacts out to peers if we're NOT inside a PeerServer because the PeerServer will
		# run a seperate timer thread to sync out transactions to peers based on the peer's last_tx_sent.
		# The push function was moved to the timer thread in PeerServer because we could get caught in a race condition
		# that looked like this:
		#    - This StorageEngine pushes a transaction to a peer (this routine)
		#    - Remote PeerServer receives a /db/tr_push from a Peer
		#    - Remote PeerServer stores the tx locally
		#    - Remote PeerServer calls it's engine->_push_tr() 
		#    - This PeerServer gets /deb/tr_push, which calls our _push_tr() [this routine]
		#    - Since the first line (above) would have already locked in update_begin(), when it hits 
		#      here now, we still would be locked...
		# However, in non-server usage (e.g. StorageEngine used in an app which is not running a PeerServer),
		# we do want to push to peers so the data gets "out of our process" (well, off our machine.) 
		#if(!$peer_server)
		if(0)
		{
			foreach my $p (@peers)
			{
				#next if $p->url !~ /10.10.9.90/; # NOTE Just for prototyping/debugging
				
				logmsg "TRACE", "StorageEngine: _push_tr(): Peer: ", $p->url, ", tr: ", $tr->uuid, "\n";
				
				if(defined $p &&
				   $p->host_down)
				{
					#logmsg "TRACE", "StorageEngine: _push_tr(): Not pushing to ", $p->url, " - it's marked as down.\n";
					next;
				}
	
				if(defined $peer_server &&
				   $peer_server->is_this_peer($p->url))
				{
					my $lock = $p->update_begin();
					$p->{last_tx_sent} = $tr->{rel_id};
					#logmsg "TRACE", "StorageEngine: _push_tr(): Not pushing to ", $p->url, " - it's our local peer and local is active.\n";
					next;
				}
				
				if(defined $skip_peer_url &&
				   $p->url eq $skip_peer_url)
				{
					my $lock = $p->update_begin();
					$p->{last_tx_sent} = $tr->{rel_id};
					#logmsg "TRACE", "StorageEngine: _push_tr(): Not pushing to ", $p->url, " by request of caller.\n";
					next;
				}

				if(defined $p->node_uuid &&
				   $tr->has_been_here($p->node_uuid))
				{
					my $lock = $p->update_begin();
					$p->{last_tx_sent} = $tr->{rel_id};

					logmsg "TRACE", "StorageEngine: _push_tr(): Not pushing to ", $p->url, " - routing history shows it was already on that host.\n";
					next;
				}
				else
				{
					logmsg "TRACE", "StorageEngine: _push_tr(): [WARN] No node_uuid for ", $p->url, " - can't check routing hist\n";
				}
				
				$p->update_begin();

				if($p->push($tr))
				{
					$p->{last_tx_sent} = $tr->{rel_id};
					debug "StorageEngine: _push_tr(): Pushed tr to $p->{url}, last_tx_sent: $tr->{rel_id}\n";
				}
				else
				{
					# TODO: Replay transactions for this peer when it comes back up
					$p->{host_down} = 1;
				}

				$p->update_end();
			}
	
# 			foreach my $p (@peers)
# 			{
# 				if(defined $peer_server &&
# 				   $peer_server->is_this_peer($p->url))
# 				{
# 					#logmsg "TRACE", "StorageEngine: _push_tr(): Not pushing to ", $p->url, " - it's our local peer and local is active.\n";
# 					next;
# 				}
# 				
# 				# Will save state if _changed is true
# 				logmsg 'debug', "Changed: $p->{_changed}\n";
# 				$p->update_end($p->{_changed});
# 			}
		}
	}

	sub _put_local
	{
		my $t = shift;
		my $key = shift;
		my $val = shift;
		
		# TODO: Purge cache/age items in ram
		#$t->{cache}->{$key} = $val;

		# TODO: Sanatize key to remove any '..' or other potentially invalid file path values
		my $key_path = $t->{db_root} . $key;
		mkpath($key_path) if !-d $key_path;

		my $key_file = $key_path . '/data';
		store({ data => $val}, $key_file);

		trace "StorageEngine: put(): key_file: $key_file\n"
			unless $key =~ /^\/global\/nodes\//;

		return $t;
	}

	sub sanatize_key
	{
		my $key = shift;
		if($key =~ /([^A-Za-z0-9 _.\-\/])/)
		{
			$@ = "Invalid character in key: '$1'";
			return undef;
		}
		$key =~ s/\.\.\///g;
		return $key;
	}

	sub get
	{
		my $self = shift;
		my $key = shift;
		my $req_uuid = shift;
		if(!$req_uuid)
		{
			$req_uuid = $ug->generate_v1->as_string();
			#logmsg "TRACE", "StorageEngine: get(): Generating new UUID $req_uuid for request for '$key'\n";
		}

		# Prevents looping
		# The 'only' way this could happen is if the $key is not on this peer and we have to check 
		# with a peer of our own, who in turn checks back with us. The idea is that the originating
		# peer would create the $req_uuid (e.g. just call get($key)) and when we pass this off
		# to another peer, we pass along the $req_uuid for calls to their storage engine, so their
		# get internally looks like get($key,$req_uuid) (our req_uuid) - so when *they* ask *us*,
		# they give us *our* req_uuid - and we say we've already seen it so just return undef
		# without checking (since we already know we dont have $key since we asked them in the first place!)
		if($self->{get_seen}->{$req_uuid})
		{
			logmsg "TRACE", "StorageEngine: get(): Already seen uuid $req_uuid\n";
			return undef;
		}
		$self->{get_seen}->{$req_uuid} = 1;

		$key = sanatize_key($key);

		if(!$key && $@)
		{
			warn "[ERROR] StorageEngine: get(): $@";
			return undef;
		}

		$key = '/'.$key if $key !~ /^\//;
		
# 		my $tr = HashNet::StorageEngine::TransactionRecord->new('MODE_KV', $key, undef, 'TYPE_READ');
# 		push @{$t->{txqueue}}, $tr;

		# TODO Update timestamp fo $key in cache for aging purposes
		#logmsg "TRACE", "get($key): Checking {cache} for $key\n";
		#return $t->{cache}->{$key} if defined $t->{cache}->{$key};

		my $key_path = $self->{db_root} . $key;
		my $key_file = $key_path . '/data';

		my $val = undef;
		if(-f $key_file)
		{
			#logmsg "TRACE", "StorageEngine: get(): Reading key_file $key_file\n";
			$val = retrieve($key_file)->{data};
			return $val;
		}

		my $peer_server = HashNet::StorageEngine::PeerServer->active_server;
		
		my $checked_peers_count = 0;
		PEER: foreach my $p (@{$self->{peers}})
		{
			next if $p->host_down;

			$checked_peers_count ++;

			if(defined $peer_server &&
				$peer_server->is_this_peer($p->url))
			{
				logmsg "TRACE", "StorageEngine: get(): Not checking ", $p->url, " for $key - it's our local peer and local server is active.\n";
				next;
			}

			if(defined ($val = $p->pull($key, $req_uuid)))
			{
				logmsg "TRACE", "StorageEngine: get(): Pulled $key from peer $p->{url}\n";
				$self->_put_local($key, $val);
				last;
			}
		}

		if($checked_peers_count <= 0)
		{
			logmsg "TRACE", "StorageEngine: get(): No peers available to check for missing key: $key\n";
		}

		#delete $self->{get_seen}->{$req_uuid};

		return $val;
	}

	sub list
	{
		my $self = shift;
		my $root = shift;

		my $db_root = $self->{db_root};

		my $key_path = $db_root;
		my $cmd = undef;

		if($root =~ /\|/)
		{
			my @keys = split /\|/, $root;
			foreach my $key (@keys)
			{
				$key = sanatize_key($key);

				if(!$key && $@)
				{
					warn "[ERROR] StorageEngine: list(): $@";
					return undef;
				}
			}
			
			if($root =~ /^\//)
			{
				$key_path .= shift @keys;  # only use first key if its marked with '/'
				$cmd  = "find $key_path | grep data";
			}
			else
			{
				#$cmd = "find $key_path -name '*$root*' | grep data";
				$cmd = "find $key_path | grep -P '(".join('|', @keys).")' | grep data";
			}
		}
		else
		{
			$root = sanatize_key($root);

			if(!$root && $@)
			{
				warn "[ERROR] StorageEngine: list(): $@";
				return undef;
			}

			if($root =~ /^\//)
			{
				$key_path .= $root;
				$cmd  = "find $key_path | grep data";
			}
			else
			{
				#$cmd = "find $key_path -name '*$root*' | grep data";
				$cmd = "find $key_path | grep '$root' | grep data";
			}
		}
		
		#my $key_file = $key_path . '/data';

		logmsg "TRACE", "StorageEngine: list(): Listing cmd: '$cmd'\n";
		#my $val = undef;
		#$val = retrieve($key_file)->{data} if -f $key_file;

		logmsg "TRACE", "StorageEngine: list(): Listing key_path $key_path\n";

		my $result = {};
		foreach my $key_file (qx { $cmd })
		{
			$key_file =~ s/[\r\n]//g;
			
			my $key = $key_file;
			$key =~ s/^$db_root//g;
			$key =~ s/\/data$//g;

			#my $value = $self->get($key);
			my $value = undef;
			if(-f $key_file)
			{
				$value = retrieve($key_file)->{data};
			}
			
			logmsg "TRACE", "StorageEngine: list(): key '$key' => '".($value||"")."'\n";
			$result->{$key} = $value;
		}

		return $result;
	}
	
	sub refresh_peers
	{
		#logmsg "TRACE", "StorageEngine: refresh_peers() start\n";
		my $self = shift;
		my $changed = 0;
		my @peers = @{ $self->peers };
		foreach my $peer (@peers)
		{
			$changed = 1 if $peer->load_changes;
		}
		$self->_sort_peers() if $changed;
		#logmsg "TRACE", "StorageEngine: refresh_peers() end\n";
	}

};
1;
