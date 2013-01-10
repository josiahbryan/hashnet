use common::sense;
{package HashNet::MP::SharedRef;

	use Tie::Hash;
	use base 'Tie::StdHash';

	use HashNet::Util::Logging;
	use Storable qw/freeze thaw nstore retrieve/;
	use Time::HiRes qw/time sleep alarm/;
	use POSIX;
	use Cwd qw/abs_path/;
	use Carp;

	sub DEBUG { 0 }

	use Tie::RefHash;
	my %ClassData;
	tie %ClassData, 'Tie::RefHash';

	my %Counts;

	## TODO: Try to use a simple tied hash to fetch/store

	sub new
	{
		my $class = shift;
		my $file = shift || "$0.dat"; #Carp::cluck __PACKAGE__."::new: Expected a filename as first argument";
		my $tied = shift || 0;

		if($tied)
		{
			my %hash;
			tie %hash, __PACKAGE__, $file;
			return \%hash;
		}
		else
		{
			my $self = $class->_create_inst($file);
			return $self;
		}
	};
	
	# Shortcut, so users can do:
	# HashNet::MP::LocalDB->handle("filename.dat")->indexed_handle("/test")
	sub indexed_handle
	{
		my $self = shift;
		my $path = shift;
		return HashNet::MP::LocalDB->indexed_handle($path, $self);
	}

	sub _create_inst
	{
		my $class = shift;
		my $file = shift;
		my $ref = shift || {};
		my $self = bless $ref, $class;
		trace "SharedRef: ", $file, ": _create_inst(): file: '$file', self: '$self'\n" if DEBUG;

		$ClassData{$self} = { data => $self, file => $file };
		
		$self->unlock_if_stale;

		$self->load_data();

		return $self;
	}

	sub TIEHASH
	{
		my $class = shift;
		my $file = shift;
		my $storage = bless {}, $class; #$class->_create_inst($file);
		$ClassData{$storage} = { data => $storage, file => $file };
		$storage->unlock_if_stale;
		$storage->load_data();
		#warn "New ".__PACKAGE__."created, stored in $storage.\n";
		trace "SharedRef: ", $file, ": TIEHASH: New tied hash created as $storage\n" if DEBUG;
		return $storage;
	}

	sub STORE
	{
		my ($self, $key, $val) = @_;
		#warn "Storing data with key $_[1] at $_[0].\n";
		#$_[0]{$_[1]} = $_[2]
		#$self->update_begin;
		$self->lock_file;
		trace "SharedRef: ", $self->file, ": STORE: $self: $key => $val\n" if DEBUG;
		$self->{$key} = $val;
		#$self->update_end;
		$self->save_data;
		$self->unlock_file;
	}

	sub FETCH
	{
		#warn "Fetching key '$_[1]' at $_[0]\n";
		#return $_[0]{$_[1]};
		my ($self, $key, $val) = @_;
		trace "SharedRef: ", $self->file, ": FETCH: $self: $key\n" if DEBUG;
		$self->load_changes;
		return $self->{$key};
	}
	

# 	sub DESTROY
# 	{
# 		my $self = shift;
# 		$self->save_data;
# 		$self->unlock_file;
# 	}

	#sub _d { $ClassData{shift()} }
	sub _d
	{
		my $ref = shift;

		return $ClassData{$ref};

# 		return $ClassData{$ref} if ref($ref) eq __PACKAGE__;
# 
# 		my $self = tied(%{$ref});
# 		print STDERR "SharedRef: _d: \$self from tied: '$self'\n";
# 		return $self;
	}
	
	sub file { shift->_d->{file} }
	
# 	sub file
# 	{
# 		my $ref = shift;
# 		my $self = ref $ref ? $ref : tied( %{ $ref } );
# 		use Data::Dumper;
# 		#print Dumper $ref, $self, \%ClassData, "$self";
# 		return $self->_d->{file};
# 	}
	
	sub data
	{
		#my $self = shift;
		#$self->load_changes;
		#return $self->{data};

		my $self = shift;
		$self->load_changes;
		return $self;
	}

	sub set_data
	{
		my $self = shift;
		my $data = shift || {};
		my $fail_on_updated = shift || 0;

		$self->update_begin;

		if($self->_d->{updated} &&
		   $fail_on_updated)
		{
			warn __PACKAGE__."::set_data: Data updated on disk prior to set_data() call, failing";
			return 0;
		}
		
		trace "SharedRef: ", $self->file, ": set_data(): ref: '$data', fail_on_updated: '$fail_on_updated'\n" if DEBUG;
		
		$self->_set_data($data);
		
		$self->update_end;
		
		return 1;
	}

	sub _set_data
	{
		my $self = shift;
		my $data = shift || {};

		if(ref $data ne 'HASH'   &&
		   ref $data ne __PACKAGE__)
		{
			Carp::cluck "SharedRef: ", $self->file, ": _set_data: \$data given not a HASH ($data)";
			return;
		}
		
		trace "SharedRef: ", $self->file, ": _set_data(): ref: '$data'\n" if DEBUG;
		
		$self->{$_} = $data->{$_} foreach keys %$data;
		
		return $self;
	}

	sub load_data
	{
		my $self = shift;
		my $file = $self->file;

		my $data = {};
		#debug "SharedRef: Loading data file '$file' in pid $$\n";
		#debug "SharedRef: ", $self->file, ": load_data\n";
		
		if(-f $file && (stat($file))[7] > 0)
		{
			#local $@;
			
			$Counts{load} ++;
			my $t1 = time();
			eval '$data = retrieve($file);';
			my $len = time - $t1;
			$Counts{load_t} += $len;

			#debug "\t\t SharedRef: ", $self->file, ": load_data: (load: $Counts{load}, $Counts{load_t} sec | store: $Counts{store}, $Counts{store_t} sec)\n" ;# if DEBUG;

			#logmsg "DEBUG", "SharedRef: ", $self->file, ": Error loading data from '$file': $@" if $@;
		}

		if(-f $file)
		{
			# Store our cache size/time in memory, so if another fork changes
			# the cache, sync_in() will notice the change and reload the cache
			$self->_d->{cache_mtime} = (stat($file))[9];
			$self->_d->{cache_size}  = (stat(_))[7];
			$self->_d->{edit_count}  = $self->_get_edit_count;

			debug "SharedRef: ", $self->file, ": load_data: cache mtime/size: ".$self->_d->{cache_mtime}.", ".$self->_d->{cache_size}."\n" if DEBUG;
		}

		$self->_set_data($data);

		#logmsg "DEBUG", "SharedRef: ", $self->file, ": load_state(): $file: node_info: ".Dumper($state->{node_info});

		$self->data_loaded_hook();

		trace "SharedRef: ", $self->file, ": load_data():  ".$self->_d->{file}." \t (+in)\n"  if DEBUG;

		return $data;
	}

	sub data_loaded_hook
	{
		my $self = shift;
		trace "SharedRef: ", $self->file, ": data_loaded_hook()\n" if DEBUG;
	}

	sub _inc_edit_count
	{
		my $self = shift;
		my $file = $self->file;
		my $count_file = "$file.counter";
		my $cnt = $self->_get_edit_count + 1;
		nstore(\$cnt, $count_file);
		return $cnt;
	}

	sub _get_edit_count
	{
		my $self = shift;
		my $file = $self->file;
		my $count_file = "$file.counter";
		my $cnt = 0;
		my $dat = \$cnt;
		if(-f $count_file && (stat($count_file))[7] > 0)
		{
			local *@;
			eval { $dat = retrieve($count_file); }
		}
		return $$dat;
	}
	
	sub delete_file
	{
		my $self = shift;
		my $file = $self->file;
		my $count_file = "$file.counter";
		unlink($file);
		unlink($count_file);
	}

	sub save_data
	{
		my $self = shift;
		my $file = $self->file;

		#trace "SharedRef: ", $self->file, ": save_data():  ".$self->_d->{file}." \t (-out)\n";# if DEBUG;
		#trace "SharedRef: ", $self->file, ": save_data():  data: ".Dumper($self);
		#print_stack_trace();

		#logmsg "DEBUG", "SharedRef: ", $self->file, ": save_data(): $file: node_info: ".Dumper($state->{node_info});

		$Counts{store} ++;
		my $t1 = time();
		nstore($self, $file);
		my $len = time - $t1;
		$Counts{store_t} += $len;

		#debug "\t\t SharedRef: ", $self->file, ": save_data: (load: $Counts{load}, $Counts{load_t} sec | store: $Counts{store}, $Counts{store_t} sec)\n";# if DEBUG;
		#debug "\t\t".get_stack_trace(0);

		# Store our cache size/time in memory, so if another fork changes
		# the cache, sync_in() will notice the change and reload the cache
		$self->_d->{cache_mtime} = (stat($file))[9];
		$self->_d->{cache_size}  = (stat(_))[7];
		$self->_d->{edit_count}  = $self->_inc_edit_count();

		debug "SharedRef: ", $self->file, ": save_data: cache mtime/size: ".$self->_d->{cache_mtime}.", ".$self->_d->{cache_size}.".".(stat(_))[1]."\n" if DEBUG;

	}

	sub lock_file
	{
		my $self = shift;
		my $time = shift || 10;
		#debug "SharedRef: ", $self->file, ": _lock_state():    ",$self->url," (...)  [$$]\n"; #: ", $self->file,"\n";
		#print_stack_trace();
		
		$self->_d->{locked} = 0 if !$self->_d->{locked};
		$self->_d->{locked} ++;
		
		#trace "\t\t SharedRef: ", $self->file, ": lock_file() + [".$self->_d->{locked}."]\n" if $self->file eq 'db.test-basic-client_queues_outgoing';# if $self->_d->{locked} < 1; # if DEBUG;
		#trace "\t\t ".get_stack_trace() if $self->file eq 'db.test-basic-client_queues_outgoing';# if $self->_d->{locked} < 1;

		return 2 if $self->_d->{locked} > 1;
		
		if(!_lock_file($self->file, $time)) # 2nd arg max sec to wait
		{
			#die "Can't lock ",$self->file;
			trace "SharedRef: ", $self->file, ": lock_file(): Can't lock file\n"; # if DEBUG;
			trace "SharedRef: lock failed at: ".get_stack_trace();
			$self->_d->{locked} --;
			return 0;
		}
		
		#trace "\t\t SharedRef: ", $self->file, ": lock_file() * [".$self->_d->{locked}."] * got lock\n" if $self->file eq 'db.test-basic-client_queues_outgoing';

		

		#debug "SharedRef: ", $self->file, ": _lock_state():    ",$self->url," (+)    [$$]\n"; #: ", $self->file,"\n";

		return 1;

	}

	sub unlock_file
	{
		my $self = shift;
		#debug "SharedRef: _unlock_state():  ",$self->url," (-)    [$$]\n"; #: ", $self->file,"\n";
		
		#trace "SharedRef: ", $self->file, ": unlock_file() - from:\n ".get_stack_trace();

		$self->_d->{locked} --;
		
		#trace "\t\t SharedRef: ", $self->file, ": unlock_file() @ [".$self->_d->{locked}."]\n"  if $self->file eq 'db.test-basic-client_queues_outgoing';# if $self->_d->{locked} <= 0;;# if DEBUG;
		#trace "\t\t ".get_stack_trace() if $self->_d->{locked} <= 0;

		return $self->_d->{locked}+1 if $self->_d->{locked} > 0;

		#trace "\t\t SharedRef: ", $self->file, ": unlock_file() -\n" if $self->file eq 'db.test-basic-client_queues_outgoing';# if DEBUG;
		_unlock_file($self->file);
		return 1;
	}
	
	
	sub unlock_if_stale
	{
		my $self = shift;
		my $file = shift;
		$file = $self->file if !$file && ref $self eq __PACKAGE__;
		return -1 if !$file;
		if($self->is_lock_stale($file))
		{
			my $lock_file = $file;
			$lock_file .= '.lock' if $lock_file !~ /\.lock$/;
			trace "SharedRef: unlock_if_stale: Found stale lock $lock_file, removing\n";
			unlink($lock_file);
			return 1;
		}
		return 0;
	}
	
	sub is_lock_stale
	{
		my $self = shift;
		my $file = shift;
		
		$file = $self->file if !$file && ref $self eq __PACKAGE__;
		return -1 if !$file;
		
		$file .= '.lock' if $file !~ /\.lock$/;
		my $fh;
		if(!-f $file)
		{
			#trace "SharedRef: is_lock_stale: File: $file - not a valid file\n";
			return 0;
		}
		
		if(!open($fh, "<$file"))
		{
			warn "is_lock_stale: Cannot read lockfile $file: $!";
			return 1;
		}
		my $pid = <$fh>;
		close($fh);
		
		$pid = int($pid);
		return 0 if !$pid;
		
		# kill 0 checks to see if its *possible* to send a signal to that process
		# Therefore, if it rewturns false, we can assume to process that locked
		# $file is gone away and we can say the lock is indeed stale
		my $stale = 0;
		if(!kill(0, $pid))
		{
			$stale = 1;
		}
		
		#trace "SharedRef: is_lock_stale: File: $file, Stale?  $stale\n";
		return $stale;
	}


	sub _lock_file
	{
		my $file  = shift;
		my $max   = shift || 3; #0.5;
		my $speed = shift || .01;

		my $result;
		my $time  = time;
		my $fh;

		#$file = abs_path($file);

		#stdout::debug("Util: +++locking $file\n");
		sleep $speed while time-$time < $max &&
			!( $result = sysopen($fh, $file.'.lock', O_WRONLY|O_EXCL|O_CREAT));
		#stdout::debug("Util: lock wait done on $file, result='$result'\n");
		
		print $fh $$, "\n" if $result;

		#die "Can't open lockfile $file.lock: $!" if !$result;
		if(!$result)
		{
			#warn "PID $$: Can't open lockfile $file.lock: $!" if !$result;
			#trace "Can't open lockfile $file.lock: $!";
			#print_stack_trace();
		}
		

		return $result;
	}

	sub _unlock_file
	{
		my $file = shift;
		#$file = abs_path($file);
		#stdout::debug("Util: -UNlocking $file\n");
		unlink($file.'.lock');
	}

	# Determine if the state is dirty by checking the mtime AND the size -
	# if either changed, assume state was updated by another process.
	sub _cache_dirty
	{
		my $self = shift;
		my $cache = $self->file;
		return 1 if !-f $cache;
		
		my $cur_mtime = (stat($cache))[9];
		my $cur_size  = (stat(_))[7];
		my $cur_cnt   = $self->_get_edit_count;
		if($cur_mtime  != $self->_d->{cache_mtime} ||
		   $cur_size   != $self->_d->{cache_size}  ||
		   $cur_cnt    != $self->_d->{edit_count})
		{
			trace "SharedRef: ", $self->file, ": _cache_dirty(): Cache is dirty\n" if DEBUG;
			return 1;
		}

		#trace "SharedRef: ", $self->file, ": _cache_dirty(): Cache not dirty, nothing changed (cur: $cur_mtime, $cur_size | old: ".$self->_d->{cache_mtime}.', '.$self->_d->{cache_size}.")\n" if DEBUG;
		return 0;
	}

	sub load_changes
	{
		my $self = shift;

		if($self->_cache_dirty)
		{
			$self->load_data;
			trace "SharedRef: ", $self->file, ": load_changes(): New data loaded\n" if DEBUG;
			return 1;
		}

		#trace "SharedRef: ", $self->file, ": load_changes(): Nothing changed\n" if DEBUG;

		return 0;
	}

	sub begin_update { shift->update_begin(@_) }
	sub update_begin
	{
		my $self = shift;
		my $cache = $self->file;
		$self->_d->{updated} = 0;

		trace "SharedRef: ", $self->file, ": update_begin()\n" if DEBUG;

		if($self->_cache_dirty)
		{
			$self->load_data;
			$self->_d->{updated} = 1;
		}

		return 0 if !$self->lock_file;

		# Returns undef if in void context
		#if(defined wantarray)
		#{
		#	return ondestroy sub { $self->update_end };
		#}

		return 1;
	}

	sub end_update { shift->update_end(@_) }
	sub update_end
	{
		my $self = shift;
		my $file = $self->file;

		my $changed = shift;
		$changed = 1 if !defined $changed;

		$self->save_data if $changed;

		$self->_d->{updated} = 0;

		# Release lock on cache
		$self->unlock_file;

		trace "SharedRef: ", $self->file, ": update_end()\n" if DEBUG;
	}
};
1;
