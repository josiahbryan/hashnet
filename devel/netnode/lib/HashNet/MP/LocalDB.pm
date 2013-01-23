use common::sense;

{package HashNet::MP::LocalDB;

	use Data::Dumper;

	use HashNet::Util::Logging;

	use HashNet::MP::SharedRef;
	
	our $DBFILE = '/var/lib/hashnet/localdb';
	
	my $ClassData = {};
	
	sub reset_cached_handles
	{
		$ClassData = {};
	}
	
	sub handle
	{
		my $class = shift;
		my $file = shift || $DBFILE;
		
		#trace  "LocalDB: handle: Getting handle for '$file'\n";
		$ClassData->{$file} = { db_file => $file } if !$ClassData->{$file};
		my $db_ctx = $ClassData->{$file};
		
		if(!$db_ctx->{db_handle})
		{
			# Call here instead of outside handle() at top of file
			# so that caller has a chance to set $DBFILE 
			cleanup_stale_locks($file);
				
			#trace  "LocalDB: handle($file): (re)opening file in pid $$\n";
			$db_ctx->{db_handle} = HashNet::MP::SharedRef->new($db_ctx->{db_file});
 			warn "Error opening $db_ctx->{db_file}: $@ $!" if ($@ || $!) && !$db_ctx->{db_handle};
		}
		return $db_ctx->{db_handle};
	}
	
	sub dump_db
	{
		shift if $_[0] eq __PACKAGE__;
		my $abs = shift || $DBFILE;
		my ($path, $file) = $abs =~ /^(.*\/)?([^\/]+)$/;
		$path = '.' if !$path;
		opendir(DIR, $path) || die "Cannot read dir '$path': $!";
		my @files = grep  { /^$file/ && -f "$path/$_" } readdir(DIR);
		closedir(DIR);
		#use Data::Dumper;
		#print STDERR "dump_db($abs = ($path|$file): ".Dumper(\@files);
		unlink("$path/$_") foreach @files;
	}
	
	sub cleanup_stale_locks
	{
		shift if $_[0] eq __PACKAGE__;
		my $abs = shift || $DBFILE;
		my ($path, $file) = $abs =~ /^(.*\/)?([^\/]+)$/;
		$path = '.' if !$path;
		opendir(DIR, $path) || die "Cannot read dir '$path': $!";
		my @files = grep  { /^$file.*\.lock$/ } readdir(DIR);
		closedir(DIR);
		#use Data::Dumper;
		#print STDERR "cleanup_stale_locks($abs = ($path|$file): ".Dumper(\@files);
		my $count = 0;
		HashNet::MP::SharedRef->unlock_if_stale("$path/$_") and $count ++ foreach @files;
		return $count;
	}
	
	sub indexed_handle
	{
		my $class = shift;
		my $path = shift;
		my $handle = shift || $class->handle;

		return undef if !$path;

		return $ClassData->{_cached_handles}->{$path} if
		       $ClassData->{_cached_handles}->{$path};
		
		#return $ClassData->{_cached_handles}->{$path}->{ref} if
		#       $ClassData->{_cached_handles}->{$path}->{pid} == $$;
		
		use Carp;
		croak "indexed_handle changed to only use path strings, not refs, as first arg" if ref $path;

		#trace "LocalDB: indexed_handle: Creating handle for path $path\n";
		$path =~ s/\//\./g;
		$path =~ s/[^a-zA-Z0-9]/_/g;

		my $file = $handle->file . $path;
		my $path_handle = $class->handle($file);

		#trace "LocalDB: indexed_handle: Path file: $file\n";

		my $idx_handle = HashNet::MP::LocalDB::IndexedTable->new($path_handle);

		#$ClassData->{_cached_handles}->{$path} = { ref=> $idx_handle, pid => $$ };
		$ClassData->{_cached_handles}->{$path} = $idx_handle;

		return $idx_handle;
	}
};

{package HashNet::MP::LocalDB::IndexedTable;

	use HashNet::Util::Logging; # qw/print_stack_trace/;
	use Data::Dumper;
	
	use overload 
		'+='	=> \&_add_row_op,
		'-='	=> \&del_row;

	sub new
	{
		my $class = shift;

		my $shared_ref = shift;
		
		my $auto_index = shift;
		$auto_index = 1 if !defined $auto_index;

		my $self  = bless {
			shared_ref => $shared_ref,
			auto_index => $auto_index,
		}, $class;

		my $data = $shared_ref;
		$data->{data} ||= {};
		$data->{idx}  ||= {};
		$data->{cnt}  ||= 0;
		$data->{keys} ||= [];

		return $self;
	}


	sub shared_ref { shift->{shared_ref} }
	sub data       {
		my $ref = shift->shared_ref;
		$ref->{data} = {} if !$ref->{data};
		return $ref->{data};
	 }
	sub index      {
		my $ref = shift->shared_ref;
		$ref->{idx} = {} if !$ref->{idx};
		return $ref->{idx};
	}
	sub cur_id     { shift->shared_ref->{cnt} }
	sub next_id    { ++ shift->shared_ref->{cnt} }
	sub keys       { @{ shift->shared_ref->{keys} || [] } }

	sub lock_file   { shift->shared_ref->lock_file(@_) }
	sub unlock_file { shift->shared_ref->unlock_file   }
	sub lock   { shift->lock_file(@_) }
	sub unlock { shift->unlock_file(@_) }

	sub begin_batch_update
	{
		my $self = shift;
		my $timeout = shift || undef;
		#$self->update_begin;
		return 0 if !$self->lock_file($timeout);
		$self->shared_ref->load_changes;
		$self->{_updates_paused} = 1;
		$self->{_update_end_count_while_locked} = 0;
		return 1;
	}

	sub in_batch_update
	{
		return shift->{_updates_paused};
	}

	sub end_batch_update
	{
		my $self = shift;
		if($self->{_updates_paused})
		{
			$self->{_updates_paused} = 0;
			$self->shared_ref->save_data if $self->{_update_end_count_while_locked};
			$self->unlock_file;
		}
	}

	sub update_begin
	{
		my $self = shift;
		return $self->shared_ref->update_begin unless $self->{_updates_paused};
		return 1;
		#$self->shared_ref->load_changes if $self->{_updates_paused};
	}
	
	sub update_end
	{
		my $self = shift;
		$self->{_update_end_count_while_locked} = 1 if $self->{_updates_paused};
		$self->shared_ref->update_end unless $self->{_updates_paused};

		#$self->{_ext_change} = 0;
	}

	sub has_external_changes
	{
		my $self = shift;
		#return 1 if $self->{_ext_change};
		$self->{_ext_change} = $self->shared_ref->_cache_dirty;
		return $self->{_ext_change};
	}
	
	sub clear_with { shift->clear(@_) }
	sub clear
	{
		my $self = shift;
		my $new = shift || {};

		$self->shared_ref->update_begin;

		my $db = $self->shared_ref;
		$db->{data} = $new->{data} || {};
		$db->{idx}  = $new->{idx}  || {};
		$db->{cnt}  = $new->{cnt}  || 0;
		$db->{keys} = $new->{keys} || [];

		$self->shared_ref->set_data($db);
		$self->update_end;

		#$self->{_ext_change} = 0;
	}
	
	sub set_index_keys
	{
		my $self = shift;
		my @keys = @_;

		$self->update_begin;

		$self->shared_ref->{keys} = \@keys;
		$self->_rebuild_index;

		$self->update_end;
	}

	# This will add $key to the list of keys to index
	# and rebuild the index
	sub add_index_key
	{
		my $self = shift;

		$self->update_begin;

		my @keys = $self->keys;
		my %keys = map { $_=>1 } @keys;

		my $updated = 0;
		my $shared_data = $self->shared_ref;
		foreach my $key (@_)
		{
			# The given key never indexed
			if(!$keys{$key})
			{
				push @keys, $key;

				$updated = 1;

				# Use this combo of set {keys} and _reindex_single_key()
				# because it will only rescan the db for that $key,
				# and not destroy the index of any keys already indexed
				# (Instead of just calling set_index_keys() with @keys)

				$shared_data->{keys} = \@keys;

				$self->_reindex_single_key($key) if @_ < 3;
			}
		}

		$self->_rebuild_index if @_ > 2;

		$self->update_end($updated);
	}
	
	sub add_row
	{
		my $self = shift;
		my $row = shift;
		
		return 1 if ! defined $row;
		
		# Protection against idiot programmers (myself) trying to add a row twice - which messes up the index and del_row calls later
		if($row->{id})
		{
			$self->update_row($row);
			return $row;
		}

		if(!$self->update_begin)
		{
			error "LocalDB: ".$self->shared_ref->file.": add_row(): Failed to lock file, refusing to add more data because it might corrupt database\n";
			return 0;
		}
		
		$row->{id} = $self->next_id;
		
		$self->data->{$row->{id}} = $row;
		
		$self->_index_row($row);

		$self->update_end;
		
		#trace "LocalDB: + add_row:    ".Dumper($row);
		
		return $row;
	}

	sub update_row
	{
		my $self = shift;
		my $row = shift;
		
		return undef if ! defined $row;

		$self->update_begin;
		
		#trace "LocalDB: update_row: $row\n";
		#trace "LocalDB: = update_row: ".Dumper($row);

		$self->data->{$row->{id}} = $row;

		$self->_index_row($row);

		$self->update_end;

		return $row;
	}
	
	# '+=' expectes $self back, not $row
	sub _add_row_op
	{
		my ($self, $row) = @_;
		$self->add_row($row);
		return $self;
	}

	sub delete { shift->del_row(@_) }
	sub del_row
	{
		my $self = shift;
		my $row  = shift;
		
		return undef if ! defined $row;
		
		my $id   = $row->{id};
		return undef if !$id;

		$self->update_begin;
		
# 		if($row->{nxthop} eq '58b4bd86-463a-4383-899c-c7163f2609b7.main')
# 		{
# 			trace "LocalDB: del_row: Deleting row with nxthop '58b4bd86-463a-4383-899c-c7163f2609b7.main'\n";
# 			print_stack_trace();
# 		}

		$self->_deindex_row($row);
		
		delete $self->data->{$id};

		$self->update_end;
		
		return $self;
	}
	
	sub add_batch
	{
		my $self = shift;

		my @rows;
		if(ref $_[0] eq 'ARRAY')
		{
			@rows = @{$_[0] || []};
		}
		else
		{
			@rows = @_;
		}
		return 1 if !@rows;


		if(!$self->update_begin)
		{
			error "LocalDB: ".$self->shared_ref->file.": add_batch(): Failed to lock file, refusing to add more data because it might corrupt database\n";
			return 0;
		}
		
		
		my $data  = $self->data;
		my $index = $self->index;
		my @keys  = $self->keys;
		
# 		use Data::Dumper;
# 		print STDERR Dumper $rows;
			
		foreach my $row (@rows)
		{
			my $id = $self->next_id;
			
			$row->{id} = $id;
			$data->{$row->{id}} = $row;
			
			# See comments on this loop below in rebuild_index() for notes on how/why
			foreach my $key (@keys)
			{
				my $val = $row->{$key};
				$index->{$key}->{$val} = {} if !$index->{$key}->{$val};
				$index->{$key}->{$val}->{$id} = 1;
			}
		}

		$self->update_end;
		
		return 1; #\@rows;
	}
	
	sub del_batch
	{
		my $self = shift;

		my @rows;
		if(ref $_[0] eq 'ARRAY')
		{
			@rows = @{$_[0] || []};
		}
		else
		{
			@rows = @_;
		}
		return 1 if !@rows;

		$self->update_begin;
		
		#trace "LocalDB: del_batch: deleting batch: ".Dumper(\@rows);
		
		my $data  = $self->data;
		my $index = $self->index;
		my @keys  = $self->keys;
		
		foreach my $row (@rows)
		{
			my $id   = $row->{id};
			next if !$id;

# 			if($row->{nxthop} eq '58b4bd86-463a-4383-899c-c7163f2609b7.main')
# 			{
# 				trace "LocalDB: del_batch: Deleting row with nxthop '58b4bd86-463a-4383-899c-c7163f2609b7.main'\n";
# 				print_stack_trace();
# 			}
			
			# See comments on this loop below in _rebuild_index() for notes on how/why
			foreach my $key (@keys)
			{
				my $val = $row->{$key};
				# If this key/val pair never indexed, then it follows that there is no $id key to delete
				next if !$index->{$key}->{$val};
				delete $index->{$key}->{$val}->{$id};
				
				# Using scalar keys per http://www.perlmonks.org/?node_id=173677
				delete $index->{$key}->{$val} if !scalar keys %{ $index->{$key}->{$val} };
			}
			
			#trace "LocalDB: del_batch: deleting data row for id: $id\n";
			delete $data->{$id};
		}

		$self->update_end;
		
		return $self;
	}
	
	sub _index_row
	{
		my $self = shift;
		my $row = shift;
		
		my $id    = $row->{id};
		my $index = $self->index;
		my @keys  = $self->keys;

		# See comments on this loop below in rebuild_index() for notes on how/why
		foreach my $key (@keys)
		{
			my $val = $row->{$key};

			# DBM::Deep errors on an undef hash key
			next if ! defined $key;
			next if ! defined $val;

			$index->{$key}->{$val} = {} if !$index->{$key}->{$val};
			$index->{$key}->{$val}->{$id} = 1;
		}
	}
	
	sub _deindex_row
	{
		my $self = shift;
		my $row = shift;
		
		my $id    = $row->{id};
		my $index = $self->index;
		my @keys  = $self->keys;
		
		# See comments on this loop below in _rebuild_index() for notes on how/why
		foreach my $key (@keys)
		{
			my $val = $row->{$key};
			# If this key/val pair never indexed, then it follows that there is no $id key to delete
			next if !$index->{$key}->{$val};
			delete $index->{$key}->{$val}->{$id};
			
			# Using scalar keys per http://www.perlmonks.org/?node_id=173677
			delete $index->{$key}->{$val} if !scalar keys %{ $index->{$key}->{$val} };
		}
	}
	
	sub _reindex_single_key
	{
		my $self = shift;
		my $key = shift;
		#trace "LocalDB: _reindex_single_key: '$key'\n";
		
		my $index = $self->index;
		
		$index->{$key} = {};
		
		# index every row of data
		my @data  = values %{ $self->data };
		foreach my $row (@data)
		{
			#next if ref $row ne 'HASH' && ! (eval '$row->{id}');
			
			# grab the id for this row
			my $id = $row->{id};
			
			my $val = $row->{$key};

			# DBM::Deep errors on an undef hash key
			next if ! defined $key;
			next if ! defined $val;
			
			# Use a hash for key/val instead of just direct scalar value storage
			# because more than one 'id' could have the same value for that key
			
			# Create the hash for the key/val pair if none exists
			$index->{$key}->{$val} = {} if !$index->{$key}->{$val};
			
			# Store the id's in a hash for key/val instead of a list [] because
			# this automatically prevents duplication accidentally of the
			# same id multiple times for the same key/val
			$index->{$key}->{$val}->{$id} = 1;
		}
	}
	
	sub _rebuild_index
	{
		my $self = shift;
		
		# get list of keys
		my @keys  = $self->keys;
		
		# clear index
		$self->shared_ref->{idx} = {};
		
		# create hash for each key
		my $index = $self->index;
		$index->{$_} = {} foreach @keys;
		
		# index every row of data
		my @data  = values %{ $self->data };
		foreach my $row (@data)
		{
			#use Data::Dumper;
			#print Dumper $row;
			#next if ref $row ne 'HASH' && ! (eval '$row->{id}');
			
			# grab the id for this row
			my $id = $row->{id};
			
			# add data for every indexed key in this row to the index
			foreach my $key (@keys)
			{
				my $val = $row->{$key};
				
				# Use a hash for key/val instead of just direct scalar value storage
				# because more than one 'id' could have the same value for that key
				
				# Create the hash for the key/val pair if none exists
				$index->{$key}->{$val} = {} if !$index->{$key}->{$val};
				
				# Store the id's in a hash for key/val instead of a list [] because
				# this automatically prevents duplication accidentally of the
				# same id multiple times for the same key/val
				$index->{$key}->{$val}->{$id} = 1;
			}
		}
	}
	
	sub by_id
	{
		my $self = shift;
		my $id = shift;
		$self->shared_ref->load_changes;
		return $self->data->{$id};
	}
	
	sub list
	{
		my $self = shift;
		my $sort_key = shift || undef;

		$self->shared_ref->load_changes;
		
		my @data = values %{ $self->data };
		return [ sort { $a->{$sort_key} <=> $b->{$sort_key} } grep { ref $_ eq 'HASH' } @data ] if defined $sort_key;
		return \@data;
	}

	sub size
	{
		my $self = shift;
		$self->shared_ref->load_changes;

		my @data = values %{ $self->data };
		return scalar @data;
	}

	sub all_by_field { shift->all_by_key(@_) }
	sub all_by_key
	{
		my $self = shift;
		# Force by_key to return an array
		my @return = $self->by_key(@_);
		return @return;
	}
	
	sub _build_id_list
	{
		my ($self, $key, $val) = @_;
		
		# DBM::Deep doesn't like undefined keys
		return () if !defined $key;
		return () if !defined $val;

		# Force shared_ref to check for changes from the disk
		$self->shared_ref->load_changes;

		#trace "IndexedTable: by_key: $key => $val\n";
		#trace "IndexedTable: Dump: ".Dumper($self);

		# If $force_index is true, then if $key was not in the original list of index keys,
		# we will automatically add it and build an index for that $key before returning
		# any results
		my $auto_index = $self->{auto_index};

		# The given key never indexed - add $key to the list of keys to index and rebuild the index
		$self->add_index_key($key) if !$self->index->{$key} && $auto_index;

		#print STDERR __PACKAGE__.": by_key: key='$key', val='$val'\n";
		#print_stack_trace() if !$val;
		my $idx = $self->index;
		
		# Assume an arrayref for $val is a boolean OR list of values to search for in $key
		if(ref $val eq 'ARRAY')
		{
			my %id_mashup;
			foreach my $real_val (@$val)
			{
				next if !$idx->{$key};
				next if !$idx->{$key}->{$real_val};
				
				# Get all the IDs that have $key/$real_val
				my @keys = keys %{ $idx->{$key}->{$real_val} };
				
				# Put the IDs in the id_mashup hash because
				# the hash will make sure each ID only occurs once in the result 
				$id_mashup{$_} = 1 foreach @keys;
			}
			
			# Return the final list of IDs
			return keys %id_mashup;
		}

		# No values exist for this value for this key
		return () if !$idx->{$key};
		return () if !$idx->{$key}->{$val};

		# Grab the list of IDs that have this key/value
		return keys %{ $idx->{$key}->{$val} };
	}

	sub _id_list_to_data
	{
		my $self = shift;
		my @id_list = @_;
		
		# This might occur if a key/val *was* indexed in the past,
		# but removed by del_row() - that would leave the key/val
		# hash, just an empty list
		return wantarray ? () : undef if !@id_list;

		# If used in a scalar context, dont bother looking up the whole list, just the first element.
		# Note that $id_list[0] is safe in assuming that @id_list has at least one element because
		# we just checked in the previous statement
		return $self->by_id($id_list[0]) if !wantarray;

		# If we got here, we are in a list context and we have at least one id in @id_list
		return map { $self->data->{$_} } @id_list;
	}
	
	sub by_field { shift->by_key(@_) }
	sub by_key
	{
		my $self = shift;

		# Rather than possibly return incorrect data or damage the file,
		# return a "not found" result if lock fails
		#return wantarray ? () : undef if ! $self->lock_file;
		$self->lock_file;

# 		if(@_ == 2)
# 		{
# 			my ($key, $val) = @_;
# 
# 			# Get list of IDs that have the requested key/val pair
# 			my @id_list = $self->_build_id_list($key, $val);
# 
# 			# Convert @id_list to actual stored data
# 			return $self->_id_list_to_data(@id_list);
# 		}

		my %pairs = @_;
		my %results;

		my $first = 1;
		foreach my $key (keys %pairs)
		{
			# Get list of IDs that have the requested key/val pair
			my @list = $self->_build_id_list($key, $pairs{$key});
			
			if($first)
			{
				# F/or first key pair, the %results hash is empty,
				# so fill it. Multiple key/value pairs
				# are assumed to be boolean "AND" (e.g. age=>19, name=>Stan is assumed to mean
				# all rows that have both 'age' == 19 && 'name' == 'Stan')
				# Therefore, we just fill the list with the results of the 'age' query
				# (assuminge 'age' was the first key) and then the next time thru, we
				# delete all the results from the hash that aren't named Stan (for example)
				%results = map { $_ => 1 } @list;
				$first = 0;

				#print "by_key: [first pair: $key/$pairs{$key}]: \@list: ".join('|',@list)."\n";
			}
			else
			{
				#print "by_key: [ 'n'  pair: $key/$pairs{$key}]: \@list: ".join('|',@list)."\n";
				
				my %id_map = map { $_ => 1 } @list;
				foreach my $id (keys %results)
				{
					# Trim the IDs in %results since we are performing
					# a boolean AND operation (e.g. a UNION of all the key/values in %pairs)
					delete $results{$id} if !$id_map{$id};
				}
			}
		}
		
		# %results just holds a list of IDs (the union of all the key/value pairs)
		my @id_list = sort keys %results;

		#print STDERR "\@id_list: ".Dumper(\@id_list);
		#print STDERR "\%pairs: ".Dumper(\%pairs);
		#print STDERR "\$self->shared_ref: ".Dumper($self->shared_ref);

		$self->unlock_file;
		
		# Convert @id_list to actual stored data
		return $self->_id_list_to_data(@id_list);
	}


};
1;
