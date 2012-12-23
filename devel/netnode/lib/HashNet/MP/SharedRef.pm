use common::sense;
{package HashNet::MP::SharedRef;

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

	## TODO: Try to use a simple tied hash to fetch/store

	sub new
	{
		my $class = shift;
		my $file = shift || Carp::cluck __PACKAGE__."::new: Expected a filename as first argument";

		my $self = bless { }, $class;

		$ClassData{$self} = { data => $self, file => $file };
		
		$self->load_data();

		trace "SharedRef: new(): file: '$file'\n" if DEBUG;
		
		return $self;
	};

# 	sub DESTROY
# 	{
# 		my $self = shift;
# 		$self->save_data;
# 		$self->unlock_file;
# 	}

	sub _d { $ClassData{shift()} }
	
	sub file { shift->_d->{file} }
	
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
		
		trace "SharedRef: set_data(): ref: '$data', fail_on_updated: '$fail_on_updated'\n" if DEBUG;
		
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
			Carp::cluck "SharedRef: _set_data: \$data given not a HASH ($data)";
			return;
		}
		
		trace "SharedRef: _set_data(): ref: '$data'\n" if DEBUG;
		
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
				$data = retrieve($file);
			};

			logmsg "DEBUG", "SharedRef: Error loading data from '$file': $@" if $@;
		}

		if(-f $file)
		{
			# Store our cache size/time in memory, so if another fork changes
			# the cache, sync_in() will notice the change and reload the cache
			$self->_d->{cache_mtime} = (stat($file))[9];
			$self->_d->{cache_size}  = (stat(_))[7];
		}

		$self->_set_data($data);

		#logmsg "DEBUG", "SharedRef: load_state(): $file: node_info: ".Dumper($state->{node_info});

		$self->data_loaded_hook();

		trace "SharedRef: load_data():  ".$self->_d->{file}." \t (+in)\n"  if DEBUG;

		return $data;
	}

	sub data_loaded_hook
	{
		trace "SharedRef: data_loaded_hook()\n" if DEBUG;
	}

	sub save_data
	{
		my $self = shift;
		my $file = $self->file;

		trace "SharedRef: save_data():  ".$self->_d->{file}." \t (-out)\n" if DEBUG;
		#print_stack_trace();

		#logmsg "DEBUG", "SharedRef: save_data(): $file: node_info: ".Dumper($state->{node_info});

		nstore($self, $file);

		# Store our cache size/time in memory, so if another fork changes
		# the cache, sync_in() will notice the change and reload the cache
		$self->_d->{cache_mtime} = (stat($file))[9];
		$self->_d->{cache_size}  = (stat(_))[7];

	}

	sub lock_file
	{
		my $self = shift;
		#debug "SharedRef: _lock_state():    ",$self->url," (...)  [$$]\n"; #: ", $self->file,"\n";
		if(!_lock_file($self->file, 3)) # 2nd arg max sec to wait
		{
			#die "Can't lock ",$self->file;
			trace "SharedRef: lock_file(): Can't lock file\n" if DEBUG;
			return 0;
		}

		#debug "SharedRef: _lock_state():    ",$self->url," (+)    [$$]\n"; #: ", $self->file,"\n";
		trace "SharedRef: lock_file() +\n" if DEBUG;
		return 1;

	}

	sub unlock_file
	{
		my $self = shift;
		#debug "SharedRef: _unlock_state():  ",$self->url," (-)    [$$]\n"; #: ", $self->file,"\n";
		_unlock_file($self->file);
		trace "SharedRef: unlock_file() -\n" if DEBUG;
	}


	sub _lock_file
	{
		my $file  = shift;
		my $max   = shift || 5;
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
		warn "Can't open lockfile $file.lock: $!" if !$result;

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
		if(-f $cache && (
			(stat($cache))[9]  != $self->_d->{cache_mtime} ||
			(stat(_))[7]       != $self->_d->{cache_size}
		))
		{
			trace "SharedRef: _cache_dirty(): Cache is dirty\n" if DEBUG;
			return 1;
		}

		trace "SharedRef: _cache_dirty(): Cache not dirty, nothing changed\n" if DEBUG;
		return 0;
	}

	sub load_changes
	{
		my $self = shift;

		if($self->_cache_dirty)
		{
			$self->load_data;
			trace "SharedRef: load_changes(): New data loaded\n" if DEBUG;
			return 1;
		}

		trace "SharedRef: load_changes(): Nothing changed\n" if DEBUG;

		return 0;
	}

	sub update_begin
	{
		my $self = shift;
		my $cache = $self->file;
		$self->_d->{updated} = 0;

		trace "SharedRef: update_begin()\n" if DEBUG;

		if(!$self->_d->{locked})
		{
			if(!$self->lock_file)
			{
				return 0;
			}
		}

		$self->_d->{locked} = 1;

		if($self->_cache_dirty)
		{
			$self->load_data;
			$self->_d->{updated} = 1;
		}

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
		$self->_d->{locked} = 0;

		trace "SharedRef: update_end()\n" if DEBUG;
	}
};
1;
