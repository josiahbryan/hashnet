package HashNet::MP::GlobalDB;
{
	use common::sense;
	
	use Storable qw/freeze thaw nstore retrieve/;
	use File::Path qw/mkpath/;
	use Data::Dumper;
	use Time::HiRes qw/time sleep/;
	use Cwd qw/abs_path/;
	#use LWP::Simple qw/getstore/; # for clone database
	use File::Temp qw/tempfile tempdir/; # for mimetype detection
	use JSON::PP qw/encode_json decode_json/; # for stringify routine
	use UUID::Generator::PurePerl;
	use HashNet::Util::Logging;
	use HashNet::Util::SNTP;
	use HashNet::Util::CleanRef;

	our $VERSION = 0.031;
		
	my $ug = UUID::Generator::PurePerl->new();

	our $DEFAULT_DB_ROOT   = '/var/lib/hashnet/db';

	sub MSG_GLOBALDB_TR { 'MSG_GLOBALDB_TR' }

#public:
	sub new
	{
		my $class = shift;
		#my $self = $class->SUPER::new();
		my $self = bless {}, $class;

		my %args = @_;


		# Create our database root
		$self->{db_root} = $args{db_root} || $DEFAULT_DB_ROOT;
		mkpath($self->{db_root}) if !-d $self->{db_root};

		# Update the SocketWorker to register a new message handler
		my $sw = $args{sw};
		if(!$sw)
		{
			#warn "GlobalDB: new(): No SocketWorker (sw) given, cannot offload data";
		}
		else
		{
			$sw->wait_for_start;
			$self->{sw} = $sw;
		}

		# rx_uuid can be given in args so GlobalDB can listen for incoming messages
		# on the queue, but doesn't transmit any (e.g. for use in MessageHub)
		my $uuid = $sw ? $sw->uuid : $args{rx_uuid};
		my $sw_handle = $sw ? $sw : 'HashNet::MP::SocketWorker';
		my $fork_pid = $sw_handle->fork_receiver(MSG_GLOBALDB_TR => sub
			{
				my $msg = shift;

				trace "GlobalDB: MSG_GLOBALDB_TR: Received new batch of data\n";
				$self->_put_local_batch($msg->{data});
				trace "GlobalDB: Done with $msg->{type} {$msg->{uuid}}\n\n\n\n";
			},
			uuid => $uuid,
			no_del => $sw ? 0 : 1);
		$self->{rx_pid} = $fork_pid;

		# Store the database version in case we need to check against future code feature changes
		my $db_data_ver_file = $self->db_root . '/.db_ver';
		my $db_ver = 0;
		$db_ver = retrieve($db_data_ver_file)->{ver} if -f $db_data_ver_file;

		nstore({ ver => $VERSION }, $db_data_ver_file) if $db_ver != $VERSION;

		return $self;
	};

	sub sw { shift->{sw} }
	
	sub DESTROY
	{
		my $self = shift;
		if($self->{rx_pid})
		{
			kill 15, $self->{rx_pid};
		}
	}

	
	
# 	sub clone_database
# 	{
# 		my $self = shift;
# 		my $peer = shift;
# 
# 		my $upgrade_url = $peer->url . '/clone_db';
# 
# 		my $tmp_file = '/tmp/hashnet-db-clone.tar.gz';
# 
# 		logmsg "INFO", "GlobalDB: clone_database(): Downloading database tar from $upgrade_url to $tmp_file\n";
# 
# 		getstore($upgrade_url, $tmp_file);
# 
# 		logmsg "INFO", "GlobalDB: clone_database(): Download finished.\n";
# 
# 		my $decomp_cmd = "tar zx -C ".$self->db_root." -f $tmp_file";
# 
# 		trace "GlobalDB: clone_database(): Decompressing: '$decomp_cmd'\n";
# 
# 		system($decomp_cmd);
# 
# 		return 1;
# 	}

	sub db_root { shift->{db_root} }

	sub begin_batch_update
	{
		my $self = shift;
		if(!$self->{_batch_update})
		{
			$self->{_batch_update} = 1;
			$self->{_batch_list}   = [];
		}
	}

	sub in_batch_update
	{
		return shift->{_batch_update} || 0;
	}

	sub end_batch_update
	{
		my $self = shift;
		$self->{_batch_update} = 0;

		my @batch = @{$self->{_batch_list} || []};
		if(!@batch)
		{
			undef $self->{_batch_list};
			#logmsg "INFO", "GlobalDB: end_batch_update(): No entries in batch list, nothing updated.\n";
			return;
		}

		# _put_local_batch will set the 'edit_num' key for each item in _batch_list so the edit_nums are stored in the $tr (by way of the reference given below)
		$self->_put_local_batch($self->{_batch_list});

		$self->_push_tr($self->{_batch_list});

		undef $self->{_batch_list};
	}

	sub _put_local_batch
	{
		my $self = shift;
		my @batch  = @{ shift || {} };
		if(!@batch)
		{
			logmsg "INFO", "GlobalDB: _put_local_batch(): No entries in batch list, nothing updated.\n";
			return;
		}

		foreach my $item (@batch)
		{
			my $data_ref = $self->_put_local($item->{key}, $item->{val}, $item->{timestamp}, $item->{edit_num});
			# Store timestamp/edit_num back into the ref inside @batch so that
			# when we upload the @batch in end_batch_update to via SocketWorker,
			# the ts/edit# is captured and sent out
			$item->{timestamp} = $data_ref->{timestamp};
			$item->{edit_num}  = $data_ref->{edit_num};
		}
	}


	sub elide_string
	{
		my $string = shift;
		my $max_len = shift || 50;

		my $len = length($string);
		if($len > $max_len)
		{
			my $elide = '...';
			my $buff  = ($max_len - length($elide)) / 2;
			my $b1    = substr($string,      0, $buff);
			my $b2    = substr($string, -$buff, $buff);
			$string   = "${b1}...${b2}";
		}
		return $string;

	}

	sub put
	{
		my $self = shift;
		my $key = shift;
		my $val = shift;

		$key = sanatize_key($key);

		if(!$key && $@)
		{
			logmsg "ERROR", "GlobalDB: put(): $@";
			return undef;
		}

		$key = '/'.$key if $key !~ /^\//;

		trace "GlobalDB: put(): '", elide_string($key), "' \t => ", (defined $val ? "'$val'" : '(undef)'), "\n";

		if($self->{_batch_update})
		{
			#logmsg "WARN", "GlobalDB: put(): [BATCH] $key => ", ($val||''), "\n";
			push @{$self->{_batch_list}}, {key=>$key, val=>$val};
			return $key;
		}

		#logmsg "TRACE", "GlobalDB: put(): $key => ", ($val||''), "\n";

		my $data_ref = $self->_put_local($key, $val);

		$self->_push_tr([{
			key		=> $key,
			val		=> $val,
			timestamp	=> $data_ref->{timestamp},
			edit_num	=> $data_ref->{edit_num},
		}]);


		return $key;
	}

	sub _push_tr
	{
		my $self = shift;
		my $tr = shift;

		my $sw = $self->{sw};
		if(!$sw)
		{
			warn "GlobalDB: No SocketWorker given, cannot upload data off this node";
		}
		else
		{
			my @args =
			(
				$tr,
				type	=> MSG_GLOBALDB_TR,
				nxthop	=> $self->sw->peer_uuid,
				curhop	=> $self->sw->uuid,
				to	=> '*',
				bcast	=> 1,
				sfwd	=> 1,
			);
			my $new_env = $self->sw->create_envelope(@args);
			$self->sw->outgoing_queue->add_row($new_env);

			trace "GlobalDB: _push_tr: new_env to nxthop {$new_env->{nxthop}}\n";
			#trace "GlobalDB: _push_tr: new_env dump: ".Dumper($new_env,$self->sw->outgoing_queue);
			$self->sw->wait_for_send(); # Make sure the data gets off this node
			#trace "GlobalDB: _push_tr: final queue: ".Dumper($self->sw->outgoing_queue);
		}
	}

	sub discover_mimetype
	{
		shift if $_[0] eq __PACKAGE__ || ref($_[0]) eq __PACKAGE__;
		my $value = shift;

		# Write the data to a tempfile
		my ($fh, $filename) = tempfile();
		print $fh $value;
		close($fh);

		# Use 'file' to deduct the mimetype of the data contained therein
		#$mimetype = `file -b --mime-type $filename`;
		#$mimetype =~ s/[\r\n]//g;

		# Use -i instead of --mime-type and parse off any extrenuous encoding info (below)
		# because older versions of `file' don't recognize --mime-type
		my $mimetype = `file -b -i $filename`;
		$mimetype =~ s/^([^\s;]+)([;\s].*)?[\r\n]*$/$1/g;

		# Remove the temp file so we dont leave data laying around
		unlink($filename);

		return $mimetype;
	}

	sub printable_value
	{
		shift if $_[0] eq __PACKAGE__ || ref($_[0]) eq __PACKAGE__;
		my $value = shift;
		return undef if !defined $value;

		if(ref($value))
		{
			return encode_json(clean_ref($value));
		}
		elsif($value =~ /[^[:print:]]/)
		{
			# contains unprintable characters
			my $mimetype = discover_mimetype($value);
			return "($mimetype, ".length($value)." bytes)";
		}
		else
		{
			return "'$value'";
		}
	}

	sub _put_local
	{
		my $self = shift;
		my $key = shift;
		my $val = shift;
		my $check_timestamp = shift || undef;
		my $check_edit_num  = shift || undef;

		return if ! defined $key;

		#trace "GlobalDB: _put_local(): '$key' \t => ", (defined $val ? "'$val'" : '(undef)'), "\n";
		trace "GlobalDB: _put_local(): '", elide_string($key), "' => ",
			(defined $val ? elide_string(printable_value($val)) : '(undef)'),
			"\n";

		# TODO: Purge cache/age items in ram
		#$t->{cache}->{$key} = $val;

		# TODO: Sanatize key to remove any '..' or other potentially invalid file path values
		my $key_path = $self->{db_root} . $key;
		mkpath($key_path) if !-d $key_path;

		my $key_file = $key_path . '/data';

		my $edit_num = 0;
		#if(defined $timestamp
		#   && -f $key_file)
		if(-f $key_file)
		{
			my $key_data = retrieve($key_file) || { edit_num => 0 }; #->{data};

			$edit_num  = $key_data->{edit_num};
			my $key_ts = $key_data->{timestamp};

			if(defined $check_timestamp &&
				   $check_timestamp < $key_ts)
			{
				logmsg "ERROR", "GlobalDB: _put_local(): Timestamp for '$key' is OLDER than timestamp in database, NOT storing (incoming time ", (date($check_timestamp))[1], " < stored ts ", (date($key_ts))[1], ")\n";
				return undef;
			}

# 			if(defined $check_edit_num &&
# 			           $check_edit_num < $edit_num)
# 			{
# 				logmsg "ERROR", "GlobalDB: _put_local(): Edit num for '$key' is older than edit num stored, NOT storing (incoming edit_num $check_edit_num < stored edit_num $edit_num)\n";
# 				return undef;
# 			}
		}

		$edit_num ++;

		my $mimetype = 'text/plain';
		#if(defined $val && $val =~ /([^\t\n\x20-x7e])/)
		if(defined $val && $val =~ /[^[:print:]]/)
		{
			#trace "GlobalDB: _put_local(): Trigger char: '$1', ", ord($1), "\n";

			$mimetype = discover_mimetype($val);

			# Just informational
			trace "GlobalDB: _put_local(): Found mime '$mimetype' for '", elide_string($key), "'\n";
		}

		my $data_ref =
		{
			data		=> $val,
			timestamp	=> $check_timestamp || time(),
			edit_num	=> $edit_num,
			mimetype	=> $mimetype,
		};
		nstore($data_ref, $key_file);

		#trace "GlobalDB: _put_local(): key_file: $key_file\n";
		#	unless $key =~ /^\/global\/nodes\//;

		return $data_ref if defined wantarray;
		undef  $data_ref; # explicitly prevent memory leaks
	}

	sub sanatize_key
	{
		my $key = shift;
		return $key if !defined $key;
		if($key =~ /([^A-Za-z0-9 _.\-\/])/)
		{
			$@ = "Invalid character in key: '$1'";
			return undef;
		}
		$key =~ s/\.\.\///g;
		return $key;
	}

	sub _retrieve
	{
		my $self = shift;
		my $key_file = shift;

		my $key_data;

		#logmsg "TRACE", "GlobalDB: _retrieve(): Reading key_file $key_file\n";

		undef $@;
		eval {
			$key_data = retrieve($key_file) || {}; #->{data};
		};
		if($@)
		{
			#system("cat $key_file");
			return undef;
		}
		else
		{
			return $key_data;
		}
	}

	sub get
	{
		my $self = shift;
		my $key = shift;

# 		my $req_uuid = shift;
# 		if(!$req_uuid)
# 		{
# 			$req_uuid = $ug->generate_v1->as_string();
# 			#logmsg "TRACE", "GlobalDB: get(): Generating new UUID $req_uuid for request for '$key'\n";
# 		}
# 
# 		# Prevents looping
# 		# The 'only' way this could happen is if the $key is not on this peer and we have to check
# 		# with a peer of our own, who in turn checks back with us. The idea is that the originating
# 		# peer would create the $req_uuid (e.g. just call get($key)) and when we pass this off
# 		# to another peer, we pass along the $req_uuid for calls to their storage engine, so their
# 		# get internally looks like get($key,$req_uuid) (our req_uuid) - so when *they* ask *us*,
# 		# they give us *our* req_uuid - and we say we've already seen it so just return undef
# 		# without checking (since we already know we dont have $key since we asked them in the first place!)
# 		if($self->{get_seen}->{$req_uuid})
# 		{
# 			logmsg "TRACE", "GlobalDB: get(): Already seen uuid $req_uuid\n";
# 			return wantarray ? () : undef;
# 		}
# 		$self->{get_seen}->{$req_uuid} = 1;

		$key = sanatize_key($key);

		if(!$key && $@)
		{
			warn "[ERROR] GlobalDB: get(): $@";
			return wantarray ? () : undef;
		}

		$key = '/'.$key if $key !~ /^\//;

# 		my $tr = HashNet::GlobalDB::TransactionRecord->new('MODE_KV', $key, undef, 'TYPE_READ');
# 		push @{$self->{txqueue}}, $tr;

		# TODO Update timestamp fo $key in cache for aging purposes
		#logmsg "TRACE", "get($key): Checking {cache} for $key\n";
		#return $self->{cache}->{$key} if defined $self->{cache}->{$key};

		my $key_path = $self->{db_root} . $key;
		my $key_file = $key_path . '/data';

		my $key_data = {};
		my $val = undef;
		if(-f $key_file && (stat($key_file))[7] > 0)
		{
			$key_data = $self->_retrieve($key_file);
			if(defined $key_data)
			{
				return wantarray ? %{$key_data || {}} : $key_data->{data}; #$val;
			}
			else
			{
				logmsg "WARN", "GlobalDB: _retrieve(): Error reading '$key' from disk: $@ - will try to get from peers\n";
			}
		}

# 		my $peer_server = HashNet::GlobalDB::PeerServer->active_server;
# 
# 		my $checked_peers_count = 0;
# 		PEER: foreach my $p (@{$self->{peers}})
# 		{
# 			next if $p->host_down;
# 
# 			$checked_peers_count ++;
# 
# 			if(defined $peer_server &&
# 				   $peer_server->is_this_peer($p->url))
# 			{
# 				logmsg "TRACE", "GlobalDB: get(): Not checking ", $p->url, " for $key - it's our local peer and local server is active.\n";
# 				next;
# 			}
# 
# 			if(defined ($val = $p->pull($key, $req_uuid)))
# 			{
# 				logmsg "TRACE", "GlobalDB: get(): Pulled $key from peer $p->{url}\n";
# 
# 				# TODO Revisit this - since we're putting an item without sending out a new TR, and since
# 				# _put_local incs the edit_num, we probably will have a newer edit_num than our peers - at least for a short while...
# 				$self->_put_local($key, $val);
# 				last;
# 			}
# 		}
# 
# 		if($checked_peers_count <= 0)
# 		{
# 			logmsg "TRACE", "GlobalDB: get(): No peers available to check for missing key: $key\n";
# 			$@ = "No peers to check for missing key '$key'";
# 			return wantarray ? () : undef;
# 		}
# 
# 		#delete $self->{get_seen}->{$req_uuid};
# 
# 		#return wantarray ? ( data => $val, timestamp => time() ) : $val;
# 
# 		# Retrieve the key data directly instead of just using the $val so we can return the $key_data if requested
# 		$key_data = $self->_retrieve($key_file);
# 		if(defined $key_data)
# 		{
# 			return wantarray ? %{$key_data || {}} : $key_data->{data}; #$val;
# 		}

		return wantarray ? () : undef;
	}

	sub list
	{
		my $self = shift;
		my $root = shift || '/';
		my $incl_meta = shift || 0;

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
					warn "[ERROR] GlobalDB: list(): $@";
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
				warn "[ERROR] GlobalDB: list(): $@";
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

		#logmsg "TRACE", "GlobalDB: list(): Listing cmd: '$cmd'\n";

		#my $val = undef;
		#$val = retrieve($key_file)->{data} if -f $key_file;

		#logmsg "TRACE", "GlobalDB: list(): Listing key_path $key_path\n";

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
				if($incl_meta)
				{
					$value = retrieve($key_file);
				}
				else
				{
					$value = retrieve($key_file)->{data};
				}
			}

			#logmsg "TRACE", "GlobalDB: list(): key '$key' => '".($value||"")."'\n";
			$result->{$key} = $value;
		}

		return $result;
	}
};
1;