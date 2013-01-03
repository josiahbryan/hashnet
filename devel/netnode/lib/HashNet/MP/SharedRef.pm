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
			#return \%hash;

			#trace "SharedRef: new: Tied hash\n";

			#$hash{test} = 1;

			#return \%hash;

			#my $self = $class->_create_inst($file, \%hash);

			#$self->{test} = 1;


			#my $file2 = $self->file();

			#die "File mismatch: '$file2' != '$file'" if $file2 ne $file;
			
			#return $self;

			return \%hash;
		}
		else
		{
			my $self = $class->_create_inst($file);
			return $self;
		}
	};

	sub _create_inst
	{
		my $class = shift;
		my $file = shift;
		my $ref = shift || {};
		my $self = bless $ref, $class;
		trace "SharedRef: ", $file, ": _create_inst(): file: '$file', self: '$self'\n" if DEBUG;

		$ClassData{$self} = { data => $self, file => $file };

		$self->load_data();

		return $self;
	}

	sub TIEHASH
	{
		my $class = shift;
		my $file = shift;
		my $storage = bless {}, $class; #$class->_create_inst($file);
		$ClassData{$storage} = { data => $storage, file => $file };
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
			warn __PACKAGE__."::set_data: Data updated on disck prior to set_data() call, failing";
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
#		debug "SharedRef: Loading data file '$file' in pid $$\n";
		
		if(-f $file && (stat($file))[7] > 0)
		{
			local $@;
			eval
			{
				$Counts{load} ++;
				my $t1 = time();
				$data = retrieve($file);
				my $len = time - $t1;
				$Counts{load_t} += $len;
				
				debug "SharedRef: ", $self->file, ": load_data: (load: $Counts{load}, $Counts{load_t} sec | store: $Counts{store}, $Counts{store_t} sec)\n"  if DEBUG;
			};

			logmsg "DEBUG", "SharedRef: ", $self->file, ": Error loading data from '$file': $@" if $@;
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

	sub save_data
	{
		my $self = shift;
		my $file = $self->file;

		trace "SharedRef: ", $self->file, ": save_data():  ".$self->_d->{file}." \t (-out)\n" if DEBUG;
		#print_stack_trace();

		#logmsg "DEBUG", "SharedRef: ", $self->file, ": save_data(): $file: node_info: ".Dumper($state->{node_info});

		$Counts{store} ++;
		my $t1 = time();
		nstore($self, $file);
		my $len = time - $t1;
		$Counts{store_t} += $len;

		debug "SharedRef: ", $self->file, ": save_data: (load: $Counts{load}, $Counts{load_t} sec | store: $Counts{store}, $Counts{store_t} sec)\n" if DEBUG;
		#print_stack_trace(1);

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
		#debug "SharedRef: ", $self->file, ": _lock_state():    ",$self->url," (...)  [$$]\n"; #: ", $self->file,"\n";
		trace "SharedRef: ", $self->file, ": lock_file() +\n" if DEBUG;
		#print_stack_trace();

		return 2 if $self->_d->{locked};

		if(!_lock_file($self->file, 3)) # 2nd arg max sec to wait
		{
			#die "Can't lock ",$self->file;
			trace "SharedRef: ", $self->file, ": lock_file(): Can't lock file\n"; # if DEBUG;
			return 0;
		}

		$self->_d->{locked} = 1;

		#debug "SharedRef: ", $self->file, ": _lock_state():    ",$self->url," (+)    [$$]\n"; #: ", $self->file,"\n";

		return 1;

	}

	sub unlock_file
	{
		my $self = shift;
		#debug "SharedRef: _unlock_state():  ",$self->url," (-)    [$$]\n"; #: ", $self->file,"\n";
		trace "SharedRef: ", $self->file, ": unlock_file() -\n" if DEBUG;
		$self->_d->{locked} = 0;
		_unlock_file($self->file);
		return 1;
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

		#die "Can't open lockfile $file.lock: $!" if !$result;
		if(!$result)
		{
			warn "PID $$: Can't open lockfile $file.lock: $!" if !$result;
			print_stack_trace();
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
