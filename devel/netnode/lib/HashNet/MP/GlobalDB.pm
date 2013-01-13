package HashNet::MP::GlobalDB;
{
	use common::sense;
	
	use Storable qw/freeze thaw nstore retrieve/;
	use File::Slurp qw/:std/; # for cloning db
	use File::Path qw/mkpath rmtree/;
	use Data::Dumper;
	use Time::HiRes qw/time sleep/;
	#use Cwd qw/abs_path/;
	use File::Temp qw/tempfile tempdir/; # for mimetype detection
	use JSON::PP qw/encode_json decode_json/; # for stringify routine
	use POSIX; # for O_EXCL, etc for sysopen() in get()
	use UUID::Generator::PurePerl;
	
	use HashNet::Util::Logging;
	use HashNet::Util::SNTP;
	use HashNet::Util::CleanRef;
	
	use HashNet::MP::SharedRef;
	use HashNet::MP::LocalDB;
	use HashNet::MP::SocketWorker;
	
	our $VERSION = 0.031;

	sub MSG_GLOBALDB_TR          { 'MSG_GLOBALDB_TR'          }
	sub MSG_GLOBALDB_GET_QUERY   { 'MSG_GLOBALDB_GET_QUERY'   }
	sub MSG_GLOBALDB_GET_REPLY   { 'MSG_GLOBALDB_GET_REPLY'   }
	sub MSG_GLOBALDB_REV_QUERY   { 'MSG_GLOBALDB_REV_QUERY'   }
	sub MSG_GLOBALDB_REV_REPLY   { 'MSG_GLOBALDB_REV_REPLY'   }
	sub MSG_GLOBALDB_BATCH_GET   { 'MSG_GLOBALDB_BATCH_GET'   }
	sub MSG_GLOBALDB_BATCH_REPLY { 'MSG_GLOBALDB_BATCH_REPLY' }
	
	# Just here so tests/sharedref-globaldb-basic.pl can turn it off so as to not clutter debug output
	our $OFFLINE_TX_ENABLED = 1;

	# Not official yet...
	our $RAW_STORE_ENABLED  = 1;

	my $UUID_GEN = UUID::Generator::PurePerl->new();
	
	sub is_folder_empty
	{
		my $dirname = shift;
		opendir(my $dh, $dirname) or die "Not a directory";
		return scalar(grep { $_ ne "." && $_ ne ".." } readdir($dh)) == 0;
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
	
	sub is_printable
	{
		shift if $_[0] eq __PACKAGE__ || ref($_[0]) eq __PACKAGE__;
		my $value = shift;
		return undef if !defined $value;
		return 0 if ref $value;
		return 0 if $value =~ /[^[:print:]]/;
		return 1;
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
	
#public:
	sub new
	{
		my $class = shift;
		@_ = (ch => shift) if @_ == 1;

		my %args = @_;
		my $self = bless \%args, $class;

		# Create our database root
		$self->{db_root} = $args{db_root};
		if(!$self->{db_root})
		{
			# Use a default root based off the LocalDB default file
			my $local_db = $HashNet::MP::LocalDB::DBFILE;
			$local_db .= '.data';
			$self->{db_root} = $local_db;
		}
		mkpath($self->{db_root}) if !-d $self->{db_root};

		# Wait for the socket worker to start if we have a handle
		# (will return right away if already started)
		my $ch = $args{ch} || $args{client_handle};
		if($ch)
		{
			$ch->wait_for_start;
			$self->{ch} = $ch;
		}
		
		$self->{shared_lock} = HashNet::MP::SharedRef->new($self->{db_root}.'/dblock');
		
		#print_stack_trace();
		#die Dumper ($self->{ch}, \%args, \@_);
		#warn "GlobalDB: new(): No SocketWorker (sw) given, cannot offload data" if !$sw;

		# Update the SocketWorker to register new message handlers
		$self->_setup_message_listeners();

		# Check version (future use in case we make data-incompatible changes which cause us to need to patch data)
		$self->_check_db_ver();
		
		# Check for 0 rev (new database) and download copy from connected hub
		$self->_check_db_rev();
		
		if($OFFLINE_TX_ENABLED)
		{
			my $tr_data_handle  = HashNet::MP::SharedRef->new($self->{db_root}.'/offline_transactions');
			my $tr_table_handle = HashNet::MP::LocalDB::IndexedTable->new($tr_data_handle);
			$self->{offline_tr_db}  = $tr_table_handle;
			
			# Pending offline transactions, send them first
			if($ch && $tr_table_handle->size > 0)
			{
				trace "GlobalDB: Found ", $tr_table_handle->size, " pending offline messages, transmitting before continuing ...\n";
				
				# TODO: Handle failure to lock
				$tr_table_handle->lock_file(30);
				my @tr_list = @{ $tr_table_handle->list || []};
				$self->_push_tr($_->{item}, 0) foreach @tr_list; # second arg (0) turns off wait_for_send
				
				$tr_table_handle->del_batch(\@tr_list);
				$tr_table_handle->unlock_file;
				
				# Wait for the transactions to make it off this node before continuing
				$ch->wait_for_send;
				
				trace "GlobalDB: Done transmitting offline messages\n";
			}
		}
		
		# Yield for incoming messages before continuing
		if($ch)
		{
			my $queue = $ch->incoming_queue;
			my $size = $queue->size;
			trace "GlobalDB: Yielding to $ch to process any incoming message before continuing ($size pending messages)...\n";
			#trace "GlobalDB: Queue: ".Dumper($queue) if $size > 0;
			# TODO: Somehow we need to make sure we get any pending _TRs from the SW...
			sleep 1 if $size > 0;
			trace "GlobalDB: Yielding from $ch done\n";
		}

		return $self;
	};
	
	sub db_lock { shift->{shared_lock} }
	
	sub delete_disk_cache
	{
		my $self = shift;
		if(!@_)
		{
			my $root = $self->{db_root};
			rmtree($root) if -d $root;
			return;
		}
		
		if(!ref $self)
		{
			my $db = shift;
			if(-d $db)
			{
				rmtree($db);
				return;
			}
			
			$db .= '.data';
			rmtree($db) if -d $db;
		}
	}

	sub client_handle { shift->{ch} }
	sub sw            {
		my $self = shift;
		my $ch   = $self->client_handle;
		return $ch ? $ch->sw : undef;
	}
	sub sw_handle     {
		my $self = shift;
		my $sw   = $self->sw;
		return $sw ? $sw : 'HashNet::MP::SocketWorker';
	}
	
	sub _setup_message_listeners
	{
		my $self = shift;
		my $sw = $self->sw;
		my $sw_handle = $self->sw_handle;
		
		# rx_uuid can be given in args so GlobalDB can listen for incoming messages
		# on the queue, but doesn't transmit any (e.g. for use in MessageHub)
		my $uuid = $sw ? $sw->uuid : $self->{rx_uuid};
		if(!$uuid)
		{
			# Unable to setup fork_receiver, no uuid given
			return undef;
		}
		
		my $fork_pid = $sw_handle->fork_receiver(

			# needs UUID to generate MSG_CLIENT_RECEIPTS automatically
			uuid   => $uuid,
			
			# Used by both clients and servers to update their local disk caches
			MSG_GLOBALDB_TR => sub {
				my $msg = shift;

				trace "GlobalDB: MSG_GLOBALDB_TR: Received new batch of data\n";
				$self->_put_local_batch($msg->{data}, 1);
				#trace "GlobalDB: Done with $msg->{type} {$msg->{uuid}}\n\n\n\n";
				trace "GlobalDB: Done with $msg->{type} {$msg->{uuid}}\n";
			},
			
			# Hubs reply to client
			MSG_GLOBALDB_GET_QUERY => sub {
				my $msg = shift;

				my $key      = $msg->{data}->{key};
				my $options  = $msg->{data}->{options};

				my $req_uuid = $options->{req_uuid};
				trace "GlobalDB: MSG_GLOBALDB_GET_QUERY: Received get req for key '$key', request UUID {$req_uuid}\n";
				
				undef $@;
				my $value = $self->get($key, %{$options || {}});
				trace "GlobalDB: MSG_GLOBALDB_GET_QUERY: after get('$key'), \$\@='$@', value='$value'\n";
				my $data = 0;
				if($@)
				{
					$data = { error => $@ };
				}
				else
				{
					$data =
					[{
						key	=> $key,
						val	=> $value,
						meta	=> $self->get_meta($key),
					}];
				}
				
				my $new_env = $sw_handle->create_envelope(
					$data,
					type	=> MSG_GLOBALDB_GET_REPLY,
					to	=> $msg->{from},
					from	=> $msg->{to},
				);
				$sw_handle->outgoing_queue->add_row($new_env);
	
				trace "GlobalDB: MSG_GLOBALDB_GET_QUERY: Reply with data '$data' for key '$key'\n";
				#trace "GlobalDB: _push_tr: new_env dump: ".Dumper($new_env,$self->sw->outgoing_queue);
				$sw_handle->wait_for_send(4, 0.1, $msg->{to}); # Make sure the data gets off this node
			},
			
			# Server side only, clients never would get this
			MSG_GLOBALDB_BATCH_GET => sub {
				my $msg = shift;

				trace "GlobalDB: MSG_GLOBALDB_BATCH_GET: Received batch dump request\n";
				#trace "GlobalDB: MSG_GLOBALDB_BATCH_GET: Dump of request msg: ".Dumper($msg)."\n";
				
				my $file = $self->gen_db_archive;
				my $buffer = read_file($file);
				my $buf_len = length($buffer);
				
				my $env = $sw_handle->create_envelope($buf_len,
					_att	=> $buffer,
					type	=> MSG_GLOBALDB_BATCH_REPLY,
					to	=> $msg->{from},
					from	=> $msg->{to},
				);
				
				#trace "GlobalDB: MSG_GLOBALDB_BATCH_GET: Enqueing new envelope: ".Dumper($env);
				$sw_handle->outgoing_queue->add_row($env);
			
			},
			
			# Client or server use
			MSG_GLOBALDB_BATCH_REPLY => sub {
				my $msg = shift;

				trace "GlobalDB: MSG_GLOBALDB_BATCH_REPLY: Received batch database dump\n";
				
				my $buffer = $msg->{_att};
				my $exp_len = $msg->{data};
				my $buf_len = length($buffer);
				
				if($buf_len != $exp_len)
				{
					trace "GlobalDB: MSG_GLOBALDB_BATCH_REPLY: Error in dump file: received $buf_len bytes, epxected $exp_len bytes\n";
				}
				
				
				my $fh;
				my $tmp_file = '/tmp/db.tar.gz';
				open($fh, ">$tmp_file") || die "Can't write to $tmp_file: $!";
				print $fh $buffer;
				close($fh);
				
				$self->apply_db_archive($tmp_file);
			},

			# Not used yet...
			MSG_GLOBALDB_REV_QUERY => sub {
				my $msg = shift;

				trace "GlobalDB: MSG_GLOBALDB_REV_QUERY\n";
				my @rev = $self->db_rev;
				#trace "GlobalDB: Done with $msg->{type} {$msg->{uuid}}\n\n\n\n";

				my @args =
				(
					{ rev => shift @rev,
					  ts  => shift @rev },
					type	=> MSG_GLOBALDB_REV_REPLY,
					to	=> $msg->{from},
					from	=> $msg->{to},
				);
				my $new_env = $sw_handle->create_envelope(@args);
				$sw_handle->outgoing_queue->add_row($new_env);
			},
		);
			
		$self->{rx_pid} = { pid => $fork_pid, started_from => $$ };
	}
	
	
	sub gen_db_archive
	{
		my $self = shift;

		my $db_root = $self->db_root;
		my $cmd = 'cd '.$db_root.'; tar -zcf $OLDPWD/db.tar.gz . 2>/dev/null; cd $OLDPWD';
		#my $cmd = 'cd '.$db_root.'; tar -zcvf $OLDPWD/db.tar.gz .; cd $OLDPWD';
		trace "GlobalDB: gen_db_archive(): Running clone cmd: '$cmd'\n";
		system($cmd);
		
 		my $out_file = 'db.tar.gz'; # in current directory
		return $out_file;
	}
	
	sub apply_db_archive
	{
		my $self = shift;
		
		my $tmp_file = shift;
		
		mkpath($self->{db_root}) if !-d $self->{db_root};

		#my $decomp_cmd = "tar zxv -C ".$self->db_root." -f $tmp_file";
		my $decomp_cmd = "tar zx -C ".$self->db_root." -f $tmp_file 2>/dev/null";

		trace "GlobalDB: apply_db_archive(): Decompressing: '$decomp_cmd'\n";

		system($decomp_cmd);

		return 1;
	}
	
	sub _check_db_ver
	{
		my $self = shift;
		
		# Store the database version in case we need to check against future code feature changes
		my $db_data_ver_file = $self->db_root . '/.db_ver';
		my $db_ver = 0;
		$db_ver = retrieve($db_data_ver_file)->{ver} if -f $db_data_ver_file;

		nstore({ ver => $VERSION }, $db_data_ver_file) if $db_ver != $VERSION;
	}
	
	sub _check_db_rev
	{
		my $self = shift;
		if($self->db_rev() <= 0)
		{
			my $sw = $self->sw;
			my $sw_handle = $self->sw_handle;
			
			trace "GlobalDB: check_db_rev: Batch update needed\n";
			my $env;
			if($sw)
			{
				trace "GlobalDB: check_db_rev: Connected as client to ".$sw->state_handle->{remote_node_info}->{name}.", sending batch request\n";
				$env = $sw->create_envelope("Batch Request", type => MSG_GLOBALDB_BATCH_GET);
			}
			else
			{
				# Must be in a MessageHub, find the first peer thats a hub and ask them
				my @list = HashNet::MP::PeerList->peers_by_type('hub');
				if(!@list)
				{
					trace "GlobalDB: check_db_rev: No hubs in database, cant get a batch update\n";	
				}
				else
				{
				
					my $hub  = shift @list;
					trace "GlobalDB: check_db_rev: Found hub in DB, '".$hub->{name}."', sending batch request\n";
					my $uuid = $self->{rx_uuid};
					$env = $sw_handle->create_envelope("Batch Request",
						type	=> MSG_GLOBALDB_BATCH_GET,
						to	=> $hub->uuid,
						from	=> $uuid,
					);
				}
				
			}
			
			$sw_handle->outgoing_queue->add_row($env) if $env;
			
			if($sw)
			{
				$sw->wait_for_send;
				
				# MSG_GLOBALDB_BATCH_REPLY is processed above
				$sw->wait_for_receive(timeout => 10, type => MSG_GLOBALDB_BATCH_REPLY);
			}
		}	
	}
	
	sub update_db_rev
	{
		my $self = shift;
		
		my $db_data_ts_file = $self->db_root . '/.db_rev';
		# TODO: Handle failure to lock
		HashNet::MP::SharedRef::_lock_file($db_data_ts_file);
		
		my $db_rev = 0;
		$db_rev = retrieve($db_data_ts_file)->{rev} if -f $db_data_ts_file;
		nstore({ ts => time(), rev => $db_rev + 1 }, $db_data_ts_file);
		
		HashNet::MP::SharedRef::_unlock_file($db_data_ts_file);
	}
	
	sub db_rev
	{
		my $self = shift;
		
		my $db_data_ts_file = $self->db_root . '/.db_rev';
		# TODO: Handle failure to lock
		HashNet::MP::SharedRef::_lock_file($db_data_ts_file);
		
		my $db_data = { ts => 0, rev => 0 };
		$db_data = retrieve($db_data_ts_file) if -f $db_data_ts_file;
		
		HashNet::MP::SharedRef::_unlock_file($db_data_ts_file);
		
		return wantarray ? ( $db_data->{rev} , $db_data->{ts} ) : $db_data->{rev};
	}
	
	sub DESTROY
	{
		my $self = shift;
		if($self->{rx_pid} &&
		   $self->{rx_pid}->{started_from} == $$)
		{
			trace "GlobalDB: DESTROY: Killing rx_pid $self->{rx_pid}->{pid}\n";
			kill 15, $self->{rx_pid}->{pid};
		}
	}
	
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

		# _put_local_batch will set the 'editnum' key for each item in _batch_list so the editnums are stored in the $tr (by way of the reference given below)
		$self->_put_local_batch($self->{_batch_list});

		$self->_push_tr($self->{_batch_list});

		undef $self->{_batch_list};
	}

	sub _put_local_batch
	{
		my $self = shift;
		my @batch  = @{ shift || {} };
		my $dont_inc_editnum = shift || 0;
		
		if(!@batch)
		{
			logmsg "INFO", "GlobalDB: _put_local_batch(): No entries in batch list, nothing updated.\n";
			return;
		}

		foreach my $item (@batch)
		{
			if($item->{_key_deleted})
			{
				$self->_delete_local($item->{key}, $item->{meta});
			}
			else
			{
				my $meta = $self->_put_local($item->{key}, $item->{val}, $item->{meta}, $dont_inc_editnum);
				
				# Store meta back into the ref inside @batch so that
				# when we upload the @batch in end_batch_update to via SocketWorker,
				# the meta is captured and sent out
				$item->{meta} = $meta;
			}
		}
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

		#trace "GlobalDB: put(): '", elide_string($key), "' \t => ", (defined $val ? "'$val'" : '(undef)'), "\n";
		trace "GlobalDB: put(): '", elide_string($key), "' => ",
			#(defined $val ? elide_string(printable_value($val)) : '(undef)'),
			(defined $val ? printable_value($val) : '(undef)'),
			"\n";


		if($self->{_batch_update})
		{
			#logmsg "WARN", "GlobalDB: put(): [BATCH] $key => ", ($val||''), "\n";
			push @{$self->{_batch_list}},
			{
				key	=> $key,
				val	=> $val,
				meta	=> $self->get_meta($key),
			};
			return $key;
		}

		#logmsg "TRACE", "GlobalDB: put(): $key => ", ($val||''), "\n";

		my $meta = $self->_put_local($key, $val);

		$self->_push_tr([{
			key	=> $key,
			val	=> $val,
			meta	=> $meta,
		}]);


		return $meta;
	}
	
	sub delete
	{
		my $self = shift;
		my $key = shift;
		
		$key = sanatize_key($key);

		if(!$key && $@)
		{
			logmsg "ERROR", "GlobalDB: delete(): $@";
			return undef;
		}

		$key = '/'.$key if $key !~ /^\//;

		trace "GlobalDB: delete(): '", elide_string($key), "'\n";

		if($self->{_batch_update})
		{
			#logmsg "WARN", "GlobalDB: delete(): [BATCH] $key\n";
			push @{$self->{_batch_list}},
			{
				key		=> $key,
				_key_deleted	=> 1,
				meta		=> $self->get_meta($key)
			};
			return $key;
		}

		#logmsg "TRACE", "GlobalDB: delete(): $key\n";

		my $meta = $self->_delete_local($key);

		$self->_push_tr([{
			key		=> $key,
			_key_deleted    => 1,
			meta		=> $meta,
		}]);
	}
	
	sub _delete_local
	{
		my $self       = shift;
		my $key        = shift;
		my $other_meta = shift || {};
		
		return if ! defined $key;

		$key = sanatize_key($key);

		if(!$key && $@)
		{
			logmsg "ERROR", "GlobalDB: put(): $@";
			return undef;
		}

		$key = '/'.$key if $key !~ /^\//;
		
		
		trace "GlobalDB: _delete_local(): '", elide_string($key), "'\n";

		# TODO: Purge cache/age items in ram
		#$t->{cache}->{$key} = $val;

		# TODO: Handle failure to lock
		$self->db_lock->lock_file;
		
		my $unlock = sub {
			$self->db_lock->unlock_file;
			return undef;
		};
		
		# TODO: Sanatize key to remove any '..' or other potentially invalid file path values
		my $key_path = $self->{db_root} . $key;
		return $unlock->() if !-d $key_path;

		my $key_data_file = $key_path . '/data';
		my $key_meta_file = $key_path . '/meta';
		if(!-f $key_data_file && 
		   !-f $key_meta_file)
		{
			rmtree($key_path) if is_folder_empty($key_path);
			return $unlock->();
		}

		my $editnum = 0;
		if(-f $key_meta_file)
		{
			my $key_meta;
			eval { $key_meta = retrieve($key_meta_file) };
			$key_meta ||= { editnum => 0 };

			$editnum    = $key_meta->{editnum};
			my $key_ts  = $key_meta->{timestamp};

			if(defined $other_meta->{timestamp} &&
				   $other_meta->{timestamp} < $key_ts)
			{
				logmsg "ERROR", "GlobalDB: _delete_local(): Timestamp for '$key' is OLDER than timestamp in database, NOT storing (incoming time ", (date($other_meta->{timestamp}))[1], " < stored ts ", (date($key_ts))[1], ")\n";
				return $unlock->();
			}
		}
		
		unlink($key_meta_file);
		unlink($key_data_file);
		
		rmtree($key_path) if is_folder_empty($key_path);
		
		$self->update_db_rev();

		$self->db_lock->unlock_file;
		
		
		my $meta_ref =
		{
			timestamp	=> $other_meta->{timestamp} || time(),
			editnum		=> $editnum,
		};
		
		return $meta_ref;
	}
	

	sub _push_tr
	{
		my $self = shift;
		my $tr = shift;
		my $no_flush = shift || 0;

		my $sw = $self->sw;
		if(!$sw)
		{
			$self->{offline_tr_db}->add_row({ item => $tr })
				if $OFFLINE_TX_ENABLED;
			#warn "GlobalDB: No SocketWorker given, cannot upload data off this node";
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
			$self->sw->wait_for_send() unless $no_flush; # Make sure the data gets off this node
			#trace "GlobalDB: _push_tr: final queue: ".Dumper($self->sw->outgoing_queue);
		}
	}

	sub _put_local
	{
		my $self = shift;
		my $key = shift;
		my $val = shift;
# 		my $check_timestamp  = shift || undef;
# 		my $check_editnum    = shift || undef;
		my $other_meta       = shift || {};
		my $dont_inc_editnum = shift || 0;
		
		return if ! defined $key;

		$key = sanatize_key($key);

		if(!$key && $@)
		{
			logmsg "ERROR", "GlobalDB: put(): $@";
			return undef;
		}

		$key = '/'.$key if $key !~ /^\//;

		#trace "GlobalDB: _put_local(): '$key' \t => ", (defined $val ? "'$val'" : '(undef)'), "\n";
		trace "GlobalDB: _put_local(): '", elide_string($key), "' => ",
			#(defined $val ? elide_string(printable_value($val)) : '(undef)'),
			(defined $val ? printable_value($val) : '(undef)'),
			"\n";

		# TODO: Purge cache/age items in ram
		#$t->{cache}->{$key} = $val;

		# TODO: Handle failure to lock
		$self->db_lock->lock_file;
		
		# TODO: Sanatize key to remove any '..' or other potentially invalid file path values
		my $key_path = $self->{db_root} . $key;
		mkpath($key_path) if !-d $key_path;

		my $key_data_file = $key_path . '/data';
		my $key_meta_file = $key_path . '/meta';

		my $editnum = 0;
		if(-f $key_meta_file)
		{
			my $key_meta;
			eval { $key_meta = retrieve($key_meta_file) };
			$key_meta ||= { editnum => 0 };

			$editnum   = $key_meta->{editnum};
			my $key_ts = $key_meta->{timestamp};

			if(defined $other_meta->{timestamp} &&
				   $other_meta->{timestamp} < $key_ts)
			{
				logmsg "ERROR", "GlobalDB: _put_local(): Timestamp for '$key' is OLDER than timestamp in database, NOT storing (incoming time ", (date($other_meta->{timestamp}))[1], " < stored ts ", (date($key_ts))[1], ")\n";
				
				$self->db_lock->unlock_file;
				return undef;
			}

# 			if(defined $check_editnum &&
# 			           $check_editnum < $editnum)
# 			{
# 				logmsg "ERROR", "GlobalDB: _put_local(): Edit num for '$key' is older than edit num stored, NOT storing (incoming editnum $check_editnum < stored editnum $editnum)\n";
# 				return undef;
# 			}
		}

		if($dont_inc_editnum && defined $other_meta->{editnum})
		{
			$editnum = $other_meta->{editnum};
		}
		else
		{
			$editnum ++ unless $dont_inc_editnum;
		}

		my $mimetype = 'text/plain';
		#if(defined $val && $val =~ /([^\t\n\x20-x7e])/)
		if(defined $val && $val =~ /[^[:print:]]/)
		{
			#trace "GlobalDB: _put_local(): Trigger char: '$1', ", ord($1), "\n";

			$mimetype = discover_mimetype($val);

			# Just informational
			trace "GlobalDB: _put_local(): Found mime '$mimetype' for '", elide_string($key), "'\n";
		}

		# Store data first, before storing meta, so the 'size' key can be set correctly
		if($RAW_STORE_ENABLED)
		{
			# By storing undefined values using nstore() instead of write_file(),
			# we avoid the following warning in File::Slurp:
			# "Use of uninitialized value $_[0] in join or string at /usr/local/share/perl5/File/Slurp.pm line 405"
			if(ref $val || !defined $val)
			{
				nstore({val => $val},  $key_data_file);
			}
			else
			{
				 write_file($key_data_file, {binmode => ':raw'}, $val);
			}
		}
		else
		{
			nstore({val => $val},      $key_data_file);
		}
		trace "GlobalDB: _put_local(): Stored ", (defined $val ? printable_value($val) : '(undef)'), " in '$key_data_file'\n";
		
		my $meta_ref =
		{
			timestamp	=> $other_meta->{timestamp} || time(),
			editnum		=> $editnum,
			mimetype	=> $mimetype,
			size		=> (stat($key_data_file))[7],
			is_ref		=> ref($val) || !defined $val ? 1:0,
		};
		
		nstore($meta_ref, $key_meta_file);
		
		$self->update_db_rev();

		#trace "GlobalDB: _put_local(): key_data_file: $key_data_file\n";
		#	unless $key =~ /^\/global\/nodes\//;

		$self->db_lock->unlock_file;
		return $meta_ref;
	}

	sub sanatize_key
	{
		my $key = shift;
		return $key if !defined $key;
		if($key =~ /([^A-Za-z0-9 _\.\-\/])/)
		{
			$@ = "Invalid character in key: '$1'";
			return undef;
		}
		$key =~ s/\.\.//g;
		$key =~ s/\/\//\//g;
		return $key;
	}

	sub _safe_retrieve
	{
		my $self = shift;
		my $file = shift;

		undef $@; 
		
		#logmsg "TRACE", "GlobalDB: _retrieve(): Reading file $file\n";
		if(! -f $file)
		{
			$@ = "File '$file' does not exist";
			return undef;
		}
		
		if((stat($file))[7] <= 0)
		{
			$@ = "File '$file' exists, but is empty";
			return undef;
		}
		
		my $data;
		eval
		{
			$data = retrieve($file) || undef;
		};
		if($@)
		{
			$@ = "Error from retrieve('$file'): $@";
			return undef;
		}
		
		return $data;
	}
	
	sub _process_key
	{
		my $self = shift;
		my $key = shift;
		
		undef $@;

		$key = sanatize_key($key);
		return wantarray ? () : undef if !$key && $@;
		
		$key = '/'.$key if $key !~ /^\//;

		my $key_path = $self->{db_root} . $key;
		my $key_data_file = $key_path . '/data';
		my $key_meta_file = $key_path . '/meta';
		
		return wantarray ? ($key_data_file, $key_meta_file) : $key_data_file;
	}

	sub get
	{
		my $self = shift;
		my $key  = shift;
		my %opts = @_;
		
		my $exclusive_create = $opts{exclusive_create} || 0;
		
		undef $@;

		$key = '/'.$key if $key !~ /^\//;
		my $key_data_file = $self->_process_key($key);
		if(!$key_data_file && $@)
		{
			warn "[ERROR] GlobalDB: get(): $@";
			$@ = "Error in key '$key': $@";
		}
			
		
		# TODO Update timestamp fo $key in cache for aging purposes
		#logmsg "TRACE", "get($key): Checking {cache} for $key\n";
		#return $self->{cache}->{$key} if defined $self->{cache}->{$key};

		my $key_data = undef;
		
		debug "GlobalDB: get(): key:'$key', key_data_file: '$key_data_file' (\$exclusive_create: '$exclusive_create')\n";
		
		# Lock data queue so we know that the fork_listener() process is not in the middle of processing while we're trying to get()
		my $sw = $self->sw;
		my $sw_handle = $self->sw_handle;
		my $queue = $self->{rx_pid}->{pid} ? $sw_handle->rx_listen_queue($self->{rx_pid}->{pid}) : undef;
		
		# TODO: Handle failure to lock
		if(defined $queue)
		{
			trace "GlobalDB: get(): Locking listen queue for worker $self->{rx_pid}->{pid}\n";
			$queue->lock_file();
		}
		
		my $file;
		if($exclusive_create)
		{
			my $key_path = $self->{db_root} . $key;
			mkpath($key_path) if !-d $key_path;
		
			my $fh;
			if(!sysopen($fh, $key_data_file, O_EXCL|O_CREAT))
			{
				if(defined $queue)
				{
					trace "GlobalDB: get(): Unlocking listen queue for worker $self->{rx_pid}->{pid}\n";
					$queue->unlock_file();
				}
				
				trace "GlobalDB: get(): exclusive_create for '$key' (file: $key_data_file) failed, propogating error\n";
				$@ = "GlobalDB::get('$key', %opts): get() failing because '$key' exists on local disk cache and exclusive_create option specified";
				
				return undef;
			}

			trace "GlobalDB: get(): Acquired exclusive_create rights on '$key' (file: $key_data_file), querying hub for additional exclusive rights\n";
			
			# Exclusive create means the file did NOT exist before we got to this line in our program
			# Therefore, there is nothing in the file to retrieve.
			# HOWEVER, since we DID open it exlusively here, we need to check with all hubs to make sure we have the ONLY key open
			# Only THEN can we return successfully
			my $found_data = $self->_query_hubs($key, %opts);
			if(!$found_data && $@)
			{
				if(defined $queue)
				{
					trace "GlobalDB: get(): Unlocking listen queue for worker $self->{rx_pid}->{pid}\n";
					$queue->unlock_file();
				}
				
				trace "GlobalDB: get(): exclusive_create/_query_hubs failure for '$key', removing lock disk cache file\n";
				unlink($key_data_file);
				
				trace "GlobalDB: get(): exclusive_create succeeded, but _query_hubs() for exclusive_create for '$key' FAILED on remote hub (\$\@=\"$@\")\n";
				$@ = "GlobalDB::get('$key', %opts): get() failing because exclusive_create for '$key' FAILED on remote hub (\$\@=\"$@\")";
			
				return undef; 
			}
			
			if(defined $queue)
			{
				trace "GlobalDB: get(): Unlocking listen queue for worker $self->{rx_pid}->{pid}\n";
				$queue->unlock_file();
			}
			
			trace "GlobalDB: get(): exclusive_create for '$key' succeded\n";
			
			# Since it's exclusive_Create, there *is not* any data in the file, just return undef and clear the error var $@
			undef $@; 
			return undef;
		}
		else
		{
			if(defined $queue)
			{
				trace "GlobalDB: get(): Unlocking listen queue for worker $self->{rx_pid}->{pid}\n";
				$queue->unlock_file();
			}
			
			return $self->_get_data($key, $key_data_file)
		}
		
		error "GlobalDB: get(): Error while trying to retrieve '$key': $@\n" if $@;
		if(defined $queue)
		{
			trace "GlobalDB: get(): Unlocking listen queue for worker $self->{rx_pid}->{pid}\n";
			$queue->unlock_file();
		}
		
		undef $@;
		my $found_data = $self->_query_hubs($key, %opts);
		if($@)
		{
			error "GlobalDB: get(): Could not get '$key' from any hub, error: \"$@\", returning\n";
			return undef;
		}
		elsif(!$found_data)
		{
			error "GlobalDB: get(): Could not get '$key' from any hub, returning\n";
			$@ = "Key '$key' not found";
			return undef;
		}
 			
 		return $self->_get_data($key, $key_data_file);
	}

	sub _get_data
	{
		my $self = shift;
		my ($key, $file) = @_;
		if($RAW_STORE_ENABLED)
		{
			my $meta = $self->get_meta($key);
			return undef if !-f $file;
			return read_file($file, binmode => ':raw') if !$meta->{is_ref};
		}
			
		return $self->_safe_retrieve($file)->{val};
	}
	
	sub get_meta
	{
		my $self = shift;
		my $key  = shift;
		my %opts = @_;
		
		undef $@;

		$key = '/'.$key if $key !~ /^\//;
		my ($key_data_file, $key_meta_file) = $self->_process_key($key);
		if(!$key_data_file && $@)
		{
			warn "[ERROR] GlobalDB: get_meta(): $@";
			$@ = "Error in key '$key': $@";
		}
			
		
		my $key_meta = undef;
		
		debug "GlobalDB: get_meta(): key:'$key', \$key_meta_file: '$key_meta_file'\n";
		
		# Lock data queue so we know that the fork_listener() process is not in the middle of processing while we're trying to get_meta()
		my $sw = $self->sw;
		my $sw_handle = $self->sw_handle;
		my $queue = $sw_handle->rx_listen_queue($self->{rx_pid}->{pid});
		
		# TODO: Handle failure to lock
		if(defined $queue)
		{
			trace "GlobalDB: get(): Locking listen queue for worker $self->{rx_pid}->{pid}\n";
			$queue->lock_file();
		}
		
		$key_meta = $self->_safe_retrieve($key_meta_file);
		if(!$key_meta && $@)
		{
			logmsg "WARN", "GlobalDB: get_meta(): Error reading '$key' from disk: $@ - will try to get from peers\n";
		}
		elsif($key_meta->{timestamp} > 0)
		{
			if(defined $queue)
			{
				trace "GlobalDB: get_meta(): Unlocking listen queue for worker $self->{rx_pid}->{pid}\n";
				$queue->unlock_file();
			}
			
			#trace "GlobalDB: get_meta(): Returning meta for key '$key' '$key_meta'\n";
			return $key_meta;
		}
		
		error "GlobalDB: get_meta(): Error while trying to retrieve '$key': $@\n" if $@;
		if(defined $queue)
		{
			trace "GlobalDB: get_meta(): Unlocking listen queue for worker $self->{rx_pid}->{pid}\n";
			$queue->unlock_file();
		}
		
		undef $@;
		my $found_data = $self->_query_hubs($key, %opts);
		if($@)
		{
			error "GlobalDB: get_meta(): Could not get meta for '$key' from any hub, error: \"$@\", returning\n";
			return undef;
		}
		elsif(!$found_data)
		{
			error "GlobalDB: get_meta(): Could not get meta for '$key' from any hub, returning\n";
			$@ = "Key '$key' not found";
			return undef;
		}
 			
 		return $self->_safe_retrieve($key_meta_file);
	}
	
	sub _query_hubs
	{
		my $self = shift;
		my $key  = shift;
		my %opts = @_;
		
		my $exclusive_create = $opts{exclusive_create} || 0;
		my $req_uuid         = $opts{req_uuid}         || undef;
		
		if(!$req_uuid)
		{
			$req_uuid = $UUID_GEN->generate_v1->as_string();
			#logmsg "TRACE", "GlobalDB: _query_hubs(): Generating new UUID $req_uuid for request for '$key'\n";
		}

		# Prevents looping
		# The 'only' way this could happen is if the $key is not on this peer and we have to check
		# with a peer of our own, who in turn checks back with us. The idea is that the originating
		# peer would create the $req_uuid (e.g. just call get($key)) and when we pass this off
		# to another peer, we pass along the $req_uuid for calls to their storage engine, so their
		# get internally looks like get($key,$req_uuid) (our req_uuid) - so when *they* ask *us*,
		# they give us *our* req_uuid - and we say we've already seen it so just return undef
		# without checking (since we already know we dont have $key since we asked them in the first place!)
		my $dbh = $self->{_localdbh};
		if(!$dbh)
		{
			$dbh = $self->{globaldb_data} = HashNet::MP::LocalDB->handle();
			if(!$dbh->{globaldb_data})
			{
				$dbh->update_begin;
				$dbh->{globaldb_data} = {};
				$dbh->update_end;
			}
		}
		
		$dbh->load_changes;
		if($dbh->{globaldb_data}->{$req_uuid})
		{
			logmsg "TRACE", "GlobalDB: _query_hubs(): Already seen uuid $req_uuid\n";
			return wantarray ? () : undef;
		}
		
		$dbh->update_begin;
		$dbh->{globaldb_data}->{$req_uuid} = 1;
		$dbh->update_end;

		my $sw = $self->sw;
		my $sw_handle = $self->sw_handle;
		
		trace "GlobalDB: _query_hubs(): Checking hubs for '$key'\n";
		
		my $found_data = 0;
		
		# Must be in a MessageHub, find the first peer thats a hub and ask them
		my @list = HashNet::MP::PeerList->peers_by_type('hub');
		if(!@list)
		{
			trace "GlobalDB: _query_hubs(): No hubs in database, cant get '$key'\n";
		}
		else
		{
			foreach my $hub (@list)
			{
				next if !$hub->is_online ||
				         $hub->uuid eq $self->{rx_uuid}; # only will be true if we are running inside a MessageHub instance
				
				trace "GlobalDB: _query_hubs(): Trying '".$hub->{name}."', sending batch request\n";
				my $uuid = $sw ? $sw->uuid : $self->{rx_uuid};
				
				my $env = $sw_handle->create_envelope(
					{
						key => $key,
						options => 
						{
							req_uuid => $req_uuid,
							exclusive_create => $exclusive_create,
						},
					},
					type	=> MSG_GLOBALDB_GET_QUERY,
					to	=> $hub->uuid,
					from	=> $uuid,
				);
				$sw_handle->outgoing_queue->add_row($env);
				
				if($sw_handle->wait_for_receive(timeout => 15, type => MSG_GLOBALDB_GET_REPLY))
				{
					my $queue = $sw_handle->incoming_queue();
					my @messages;
					$queue->begin_batch_update;
					eval
					{
						my @tmp = $queue->by_key(to => $uuid, type => MSG_GLOBALDB_GET_REPLY);
						@messages = map { clean_ref($_) } grep { defined $_ } @tmp;
						$queue->del_batch(\@tmp);
					};
					error "GlobalDB: _query_hubs(): Error getting data from incoming message queue: $@" if $@;
					$queue->end_batch_update;
					
					if(@messages > 1)
					{
						error "GlobalDB: _query_hubs(): More than one 'MSG_GLOBALDB_GET_REPLY' received, only using first: ".Dumper(\@messages);
					}
					
					my $msg = shift @messages;
					if($msg->{data})
					{
						if(ref($msg->{data}) eq 'HASH' && $msg->{data}->{error})
						{
							trace "GlobalDB: _query_hubs(): Hub '".$hub->{name}."' encountered error while retrieving '$key', will propogate: $msg->{data}->{error}\n";
							if($exclusive_create)
							{
								$found_data = 1;
								last;
							}
							else
							{
								$dbh->update_begin;
								delete $dbh->{globaldb_data}->{$req_uuid};
								$dbh->update_end;
								
								$@ = $msg->{data}->{error};
								return 0;
							}
						}
						else
						{
							trace "GlobalDB: _query_hubs(): Hub '".$hub->{name}."' successfully provided data for '$key'\n";
							$self->_put_local_batch($msg->{data}, 1);
							
							$found_data = 1;
							last;
						}
					}
					else
					{
						trace "GlobalDB: _query_hubs(): Hub '".$hub->{name}."' replied FALSE for '$key'\n";
						#trace "GlobalDB: _query_hubs(): Hub '".$hub->{name}."' false debug: ".Dumper($msg);
					}
				}
			}
		}
		
		$dbh->update_begin;
 		delete $dbh->{globaldb_data}->{$req_uuid};
 		$dbh->update_end;
 		
 		return $found_data;
	}

	sub get_all
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

		#my $key_data_file = $key_path . '/data';

		#logmsg "TRACE", "GlobalDB: list(): Listing cmd: '$cmd'\n";

		#my $val = undef;
		#$val = retrieve($key_data_file)->{data} if -f $key_data_file;

		#logmsg "TRACE", "GlobalDB: list(): Listing key_path $key_path\n";

		my $result = {};
		foreach my $key_data_file (qx { $cmd })
		{
			$key_data_file =~ s/[\r\n]//g;

			my $key = $key_data_file;
			$key =~ s/^$db_root//g;
			$key =~ s/\/data$//g;

			#my $value = $self->get($key);
			my $value = undef;
			if(-f $key_data_file)
			{
				#$value = $self->_safe_retrieve($key_data_file)->{val};
				$value = $self->_get_data($key, $key_data_file);
				
				if($incl_meta)
				{
					my $meta = $self->get_meta($key) || {};
					$meta->{data} = $value;
					$value = $meta; 
				}
			}

			#logmsg "TRACE", "GlobalDB: list(): key '$key' => '".($value||"")."'\n";
			$result->{$key} = $value;
		}

		return $result;
	}
	
	sub lock_key
	{
		my $self = shift;
		my $key = shift;
		my %opts = @_;

		trace "GlobalDB: lock_key(): $key\n";

		# Store lock in database
		my $time  = time();
		my $max   = $opts{timeout} || 10;
		my $speed = $opts{speed}   || 1;
		my $lock_timeout = 1;
		while( time - $time < $max )
		{ 
			undef $@;
			$self->get($key.".lock", exclusive_create => 1);
			if(!$@)
			{
				$lock_timeout = 0;
				last;
			}
			else
			{
				#trace "GlobalDB: lock_key(): In lock loop, failure msg: '$@'\n";
			}
			sleep $speed;
		}
		
		if($lock_timeout)
		{
			my $hashref = $self->get($key.".lock");
			trace "GlobalDB: lock_key(): Lock FAIL: Peer $hashref->{locking_name}{$hashref->{locking_uuid}} has $key locked\n";
			return 0;
		}
		
		my $sw = $self->sw;
		my $uuid = $sw ? $sw->uuid : $self->{rx_uuid};
		$self->put($key.".lock", { locking_uuid => $uuid, locking_pid => $$, locking_name => $sw ? $sw->node_info->{name} : "(name unknown)" });
		
		trace "GlobalDB: lock_key(): Successfully locked '$key', replying SUCCESS to lock request\n";
		return 1;
	}

	sub unlock_key
	{
		my $self = shift;
		my $key  = shift;

		trace "GlobalDB: unlock: $key\n";

		$self->delete($key.".lock");

		return 1;
	}

	sub is_lock_stale
	{
		my $self = shift;
		my $key = shift;
		my $ping_max_time = shift || 10;

		my $lock_key = "$key.lock";
		
		my $hashref = $self->get($lock_key);
		if($hashref)
		{
			my $uuid = $hashref->{locking_uuid};
			my @results;
			
			if($self->sw)
			{
				# TODO: Check send_ping() to see if its compatible with being called from a message hub
				@results = $self->sw->send_ping($uuid, $ping_max_time);
			}

			@results = grep { $_->{msg}->{from} eq $uuid } @results;
			if(!@results)
			{
				trace "GlobalDB: is_lock_stale: Lock for '$key' is stale\n";
				
				my $sw = $self->sw;
				my $my_uuid = $sw ? $sw->uuid : $self->{rx_uuid};
				if($my_uuid eq $uuid)
				{
					# Check to see if that PID is still up before declaring lock stale
					my $stale = 0;
					if(!kill(0, $hashref->{locking_pid}))
					{
						$stale = 1;
					}
					
					return $stale;
				}
				
				return 1;
			}
			else
			{
				trace "GlobalDB: is_lock_stale: Lock for '$key' is NOT stale, locking UUID {$uuid} still alive\n";
			}
		}
		return 0;
	}

	sub unlock_if_stale
	{
		my $self = shift;
		
		my $key = shift;
		my $ping_max_time = shift || 10;

		my $lock_key = "$key.lock";

		trace "GlobalDB: unlock_if_stale: '$key'\n";

		if($self->is_lock_stale($key, $ping_max_time))
		{
			# TODO: Do we need to do some sort of force-push_tr incase we're inside a batch...?
			$self->delete($lock_key);
			return 1;
		}
		else
		{
			#trace "GlobalDB: unlock_if_stale: Lock for '$key' is NOT stale, locking UUID {$uuid} still alive\n";
			return 0;
		}
	}
};
1;
