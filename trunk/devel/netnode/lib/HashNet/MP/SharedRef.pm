use common::sense;
{package HashNet::MP::SharedRef;

	use HashNet::Util::Logging;
	use Storable qw/freeze thaw nstore retrieve/;
	use Time::HiRes qw/time sleep alarm/;
	use POSIX;
	use Cwd qw/abs_path/;
	use Carp;

	sub DEBUG { 0 }

	sub new
	{
		my $class = shift;
		my $file = shift || Carp::cluck __PACKAGE__."::new: Expected a filename as first argument";
		my $self = bless
		{
			file => $file,
			data => {},
		};
		$self->load_data();
		
		return $self;
	};

# 	sub DESTROY
# 	{
# 		my $self = shift;
# 		$self->save_data;
# 		$self->unlock_file;
# 	}

	sub file { shift->{file} }
	
	sub data
	{
		my $self = shift;
		$self->load_changes;
		return $self->{data};
	}

	sub set_data
	{
		my $self = shift;
		my $data = shift;
		my $fail_on_updated = shift || 0;
		$self->update_begin;
		if($self->{updated} && $fail_on_updated)
		{
			warn __PACKAGE__."::set_data: Data updated on disck prior to set_data() call, failing";
			return 0;
		}
		$self->{data} = $data;
		$self->update_end;
		return 1;
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
				#$state = retrieve($file) if -f $file && (stat($file))[7] > 0;

				#system("cat $file");

				#$state = YAML::Tiny::LoadFile($file);
				$data = retrieve($file);
			};

			logmsg "DEBUG", "SharedRef: Error loading data from '$file': $@" if $@;
		}

		if(-f $file)
		{
			# Store our cache size/time in memory, so if another fork changes
			# the cache, sync_in() will notice the change and reload the cache
			$self->{cache_mtime} = (stat($file))[9];
			$self->{cache_size}  = (stat(_))[7];
		}

		$self->{data} = $data;

		#logmsg "DEBUG", "SharedRef: load_state(): $file: node_info: ".Dumper($state->{node_info});

		$self->data_loaded_hook();

		trace "SharedRef: Load data:  $self->{file} \t (+in)\n"  if DEBUG;

		return $data;
	}

	sub data_loaded_hook {}

	sub save_data
	{
		my $self = shift;
		my $file = $self->file;

		trace "SharedRef: Save data:  $self->{file} \t (-out)\n" if DEBUG;
		#print_stack_trace();

		#logmsg "DEBUG", "SharedRef: save_data(): $file: node_info: ".Dumper($state->{node_info});

		nstore($self->{data}, $file);

		# Store our cache size/time in memory, so if another fork changes
		# the cache, sync_in() will notice the change and reload the cache
		$self->{cache_mtime} = (stat($file))[9];
		$self->{cache_size}  = (stat(_))[7];

	}

	sub lock_file
	{
		my $self = shift;
		#debug "SharedRef: _lock_state():    ",$self->url," (...)  [$$]\n"; #: ", $self->file,"\n";
		if(!_lock_file($self->file, 3)) # 2nd arg max sec to wait
		{
			#die "Can't lock ",$self->file;
			return 0;
		}

		#debug "SharedRef: _lock_state():    ",$self->url," (+)    [$$]\n"; #: ", $self->file,"\n";
		return 1;

	}

	sub unlock_file
	{
		my $self = shift;
		#debug "SharedRef: _unlock_state():  ",$self->url," (-)    [$$]\n"; #: ", $self->file,"\n";
		_unlock_file($self->file);

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
			(stat($cache))[9]  != $self->{cache_mtime} ||
			(stat(_))[7]       != $self->{cache_size}
		))
		{
			return 1;
		}

		return 0;
	}

	sub load_changes
	{
		my $self = shift;

		if($self->_cache_dirty)
		{
			$self->load_data;
			return 1;
		}

		return 0;
	}

	sub update_begin
	{
		my $self = shift;
		my $cache = $self->file;
		$self->{updated} = 0;

		if(!$self->{locked})
		{
			if(!$self->lock_file)
			{
				return 0;
			}
		}

		$self->{locked} = 1;

		if($self->_cache_dirty)
		{
			$self->load_data;
			$self->{updated} = 1;
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

		$self->{updated} = 0;

		# Release lock on cache
		$self->unlock_file;
		$self->{locked} = 0;
	}
};
1;
