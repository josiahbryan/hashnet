use common::sense;

{package HashNet::MP::LocalDB;

	use DBM::Deep;

	use HashNet::Util::Logging;

	use HashNet::MP::SharedRef;
	
	our $DBFILE = '/var/lib/hashnet/localdb';
	
	my $class_data = {};
	
	sub reset_cached_handles
	{
		$class_data = {};
	}
	
	sub handle
	{
		my $class = shift;
		my $file = shift || $DBFILE;
		
		#trace  "LocalDB: handle: Getting handle for '$file'\n";
		
		$class_data->{$file} = { db_file => $file } if !$class_data->{$file};
		my $db_ctx = $class_data->{$file};
		
		if(!$db_ctx->{db_handle})
		{
			#trace  "LocalDB: handle($file): (re)opening file in pid $$\n";
			$db_ctx->{db_handle} = HashNet::MP::SharedRef->new($db_ctx->{db_file});
 			warn "Error opening $db_ctx->{db_file}: $@ $!" if ($@ || $!) && !$db_ctx->{db_handle};
		}
		return $db_ctx->{db_handle};
	}

	
	sub indexed_handle
	{
		my $class = shift;
		my $path = shift;
		my $handle = shift || $class->handle;

		return undef if !$path;

		return $class_data->{_cached_handles}->{$path} if
		       $class_data->{_cached_handles}->{$path};
		
		#return $class_data->{_cached_handles}->{$path}->{ref} if
		#       $class_data->{_cached_handles}->{$path}->{pid} == $$;
		
		use Carp;
		croak "indexed_handle changed to only use path strings, not refs, as first arg" if ref $path;

		#trace "LocalDB: indexed_handle: Creating handle for path $path\n";
		$path =~ s/\//\./g;
		$path =~ s/[^a-zA-Z0-9]/_/g;

		my $file = $handle->file . $path;
		my $path_handle = $class->handle($file);

		#trace "LocalDB: indexed_handle: Path file: $file\n";

		my $idx_handle = HashNet::MP::LocalDB::IndexedTable->new($path_handle);

		#$class_data->{_cached_handles}->{$path} = { ref=> $idx_handle, pid => $$ };
		$class_data->{_cached_handles}->{$path} = $idx_handle;

		return $idx_handle;
	}
};

{package HashNet::MP::LocalDB::IndexedTable;

	use HashNet::Util::Logging qw/print_stack_trace/;
	
	use overload 
		'+='	=> \&_add_row_op,
		'-='	=> \&del_row;
	
# 	sub new
# 	{
# 		my $class = shift;
# 		my $ref   = shift;
# 		my $auto_index = shift;
# 		$auto_index = 1 if !defined $auto_index;
# 		
# 		my $self  = bless
# 		{
# 			db => $ref,
# 			auto_index => $auto_index,
# 		}, $class;
# 		
# 		$ref->{data} ||= {};
# 		$ref->{idx}  ||= {};
# 		$ref->{cnt}  ||= 0;
# 		$ref->{keys} ||= []; 
# 		
# 		return $self;
# 	}


	sub new
	{
		my $class = shift;

		my $shared_ref = shift;
		
		my $auto_index = shift;
		$auto_index = 1 if !defined $auto_index;

		my $self  = bless
		{
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
	sub data       { shift->shared_ref->{data} }
	sub index      {
		my $data = shift->shared_ref;
		$data->{idx} = {} if !$data->{idx};
		return $data->{idx};
	}
	sub cur_id     { shift->shared_ref->{cnt} }
	sub next_id    { ++ shift->shared_ref->{cnt} }
	sub keys       { @{ shift->shared_ref->{keys} || [] } }

	sub update_begin { shift->shared_ref->update_begin }
	sub update_end   { shift->shared_ref->update_end }
	
	sub clear
	{
		my $self = shift;

		$self->shared_ref->update_begin;

		my $db = $self->shared_ref;
		$db->{data} = {};
		$db->{idx}  = {};
		$db->{cnt}  = 0;
		$db->{keys} = [];

		$self->shared_ref->set_data($db);
		$self->update_end;
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

		my $shared_data = $self->shared_ref;
		foreach my $key (@_)
		{
			# The given key never indexed
			#if(!$shared_data->{index}->{$key})
			if(!$keys{$key})
			{
				push @keys, $key;

				# Use this combo of set {keys} and _reindex_single_key()
				# because it will only rescan the db for that $key,
				# and not destroy the index of any keys already indexed
				# (Instead of just calling set_index_keys() with @keys)

				$shared_data->{keys} = \@keys;

				$self->_reindex_single_key($key) if @_ < 3;
			}
		}

		$self->_rebuild_index if @_ > 2;

		$self->update_end;
	}
	
	sub add_row
	{
		my $self = shift;
		my $row = shift;

		$self->update_begin;
		
		$row->{id} = $self->next_id;
		
		$self->data->{$row->{id}} = $row;
		
		$self->_index_row($row);

		$self->update_end;
		
		return $row;
	}

	sub update_row
	{
		my $self = shift;
		my $row = shift;

		$self->update_begin;

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
	
	sub del_row
	{
		my $self = shift;
		my $row  = shift;
		my $id   = $row->{id};
		return undef if !$id;

		$self->update_begin;
		
		$self->_deindex_row($row);
		
		delete $self->data->{$id};

		$self->update_end;
		
		return $self;
	}
	
	sub add_batch
	{
		my $self = shift;
		my $rows = shift;
		
		my @rows = @{$rows || []};
		return undef if !@rows;

		$self->update_begin;
		
		my $data  = $self->data;
		my $index = $self->index;
		my @keys  = $self->keys;
		
# 		use Data::Dumper;
# 		print STDERR Dumper $rows;
			
		my @out;
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
			
			push @out, $row;
		}

		$self->update_end;
		
		return \@out;
	}
	
	sub del_batch
	{
		my $self = shift;
		my $rows = shift;
		my @rows = @{$rows || []};
		return if !@rows;

		$self->update_begin;
		
		my $data  = $self->data;
		my $index = $self->index;
		my @keys  = $self->keys;
		
		foreach my $row (@rows)
		{
			my $id   = $row->{id};
			next if !$id;
			
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
		
		my $index = $self->index;
		
		$index->{$key} = {};
		
		# index every row of data
		my @data  = values %{ $self->data };
		foreach my $row (@data)
		{
			next if ref $row ne 'HASH';
			
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
			next if ref $row ne 'HASH';
			
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
		return $self->data->{$id};
	}
	
	sub list
	{
		my $self = shift;
		my $sort_key = shift || undef;
		
		my @data = values %{ $self->data };
		return [ sort { $a->{$sort_key} <=> $b->{$sort_key} } grep { ref $_ eq 'HASH' } @data ] if defined $sort_key;
		return \@data;
	}

	sub all_by_field { shift->all_by_key(@_) }
	sub all_by_key
	{
		my $self = shift;
		# Force by_key to return an array
		my @return = $self->by_key(@_);
		return @return;
	}
	
	sub by_field { shift->by_key(@_) }
	sub by_key
	{
		my $self = shift;
		my $key = shift;
		my $val = shift;
		
		# DBM::Deep doesn't like undefined keys
		return wantarray ? () : undef if !defined $key;
		return wantarray ? () : undef if !defined $val;

		# Force shared_ref to check for changes from the disk
		$self->shared_ref->load_changes;

		# If $force_index is true, then if $key was not in the original list of index keys,
		# we will automatically add it and build an index for that $key before returning
		# any results
		my $auto_index = $self->{auto_index};
		
		# The given key never indexed - add $key to the list of keys to index and rebuild the index
		$self->add_index_key($key) if !$self->index->{$key} && $auto_index;
		
		#print STDERR __PACKAGE__.": by_key: key='$key', val='$val'\n";
		#print_stack_trace() if !$val;
		
		# No values exist for this value for this key
		return wantarray ? () : undef if !$self->index->{$key};
		return wantarray ? () : undef if !$self->index->{$key}->{$val};
		
		# Grab the list of IDs that have this key/value
		my @id_list = keys %{ $self->index->{$key}->{$val} };
		
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
};
1;
