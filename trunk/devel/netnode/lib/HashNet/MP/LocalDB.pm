
{package HashNet::MP::LocalDB;

	use common::sense;
	
	use DBM::Deep;

	use HashNet::Util::Logging;
	
	our $DBFILE = '/var/lib/hashnet/local.db';
	
	my $data = {};

	use Fcntl qw( :DEFAULT :flock :seek );
	sub reset_cached_handles
	{
		foreach my $file (keys %$data)
		{
			my $ctx = $data->{$file};
			my $fh = $ctx->{db_handle}->_storage();
			trace "LocalDB: reset_cached_handles: Unlocking $file, fh $fh\n";
			flock($fh, LOCK_UN);
		}
		$data = {};
	}
	
	sub handle
	{
		my $class = shift;
		my $file = shift || $DBFILE;
		
		#trace  "LocalDB: handle: Getting handle for '$file'\n";
		
		$data->{$file} = { db_file => $file } if !$data->{$file};
		my $db_ctx = $data->{$file};
		
		if(!$db_ctx->{db_handle} ||
		  # Re-create the DBM::Deep object when we change PIDs -
		  # e.g. when someone forks a process that we are in.
		  # I learned the hard way (via multiple unexplainable errors)
		  # that DBM::Deep does NOT like existing before forks and used
		  # in child procs. (Ref: http://stackoverflow.com/questions/11368807/dbmdeep-unexplained-errors)
		  ($db_ctx->{_db_handle_pid}||0) != $$)
		{
			#trace  "LocalDB: handle($file): (re)opening file in pid $$\n";
			$db_ctx->{db_handle} = DBM::Deep->new(#$db_ctx->{db_file});
 				file	  => $db_ctx->{db_file},
 				locking   => 1, # enabled by default, just here to remind me
 				autoflush => 1, # enabled by default, just here to remind me
# 				#type => DBM::Deep->TYPE_ARRAY
 			);
 			warn "Error opening $db_ctx->{db_file}: $@ $!" if ($@ || $!) && !$db_ctx->{db_handle};
			$db_ctx->{_db_handle_pid} = $$;
		}
		return $db_ctx->{db_handle};
	}
	
	sub indexed_handle
	{
		my $class = shift;
		my $ref = shift;
		my $handle = shift || $class->handle;
		
		return undef if !$ref;
		#trace "LocalDB: indexed_handle: Creating handle for ref $ref\n";
		
		if(!ref $ref)
		{
			my @path = split /\//, $ref;
			shift @path if !$path[0];
			
			my $path = shift @path;
			$handle->{$path} = {} if ! $handle->{$path};
			$ref = $handle->{$path};
			
			foreach $path (@path)
			{
				$ref->{$path} = {} if !$ref->{$path};
				$ref = $ref->{$path};
			}
		}
		
		return HashNet::MP::LocalDB::IndexedTable->new($ref);
	}
};

{package HashNet::MP::LocalDB::IndexedTable;

	use common::sense;
	
	use HashNet::Util::Logging qw/print_stack_trace/;
	
	
	
	use overload 
		'+='	=> \&_add_row_op,
		'-='	=> \&del_row;
	
	sub new
	{
		my $class = shift;
		my $ref   = shift;
		my $auto_index = shift;
		$auto_index = 1 if !defined $auto_index;
		
		my $self  = bless
		{
			db => $ref,
			auto_index => $auto_index,
		}, $class;
		
		$ref->{data} ||= {};
		$ref->{idx}  ||= {};
		$ref->{cnt}  ||= 0;
		$ref->{keys} ||= []; 
		
		return $self;
	}
	
	sub db      { shift->{db} }
	sub data    { shift->db->{data} }
	sub index   { shift->db->{idx} }
	sub cur_id  { shift->db->{cnt} }
	sub next_id { ++ shift->db->{cnt} }
	
	sub clear
	{
		my $self = shift;
		$self->db->{data} = {};
		$self->db->{idx}  = {};
		$self->db->{cnt}  = 0;
	}
	
	sub set_index_keys
	{
		my $self = shift;
		my @keys = @_;
		$self->db->{keys} = \@keys;
		
		$self->_rebuild_index;
	}

	# This will add $key to the list of keys to index
	# and rebuild the index
	sub add_index_key
	{
		my $self = shift;

		foreach my $key (@_)
		{
			# The given key never indexed
			if(!$self->index->{$key})
			{
				my @keys  = @{ $self->db->{keys} };
				push @keys, $key;

				# Use this combo of set {keys} and _reindex_single_key()
				# because it will only rescan the db for that $key,
				# and not destroy the index of any keys already indexed
				# (Instead of just calling set_index_keys() with @keys)

				$self->db->{keys} = \@keys;

				$self->_reindex_single_key($key) if @_ < 3;
			}
		}

		$self->_rebuild_index if @_ > 2;
	}
	
	sub add_row
	{
		my $self = shift;
		my $row = shift;
		
		$row->{id} = $self->next_id;
		
		$self->data->{$row->{id}} = $row;
		
		$self->_index_row($row);
		
		# return the value from the hash so the user gets the blessed DBM::Deep ref
		return $self->data->{$row->{id}};
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
		
		$self->_deindex_row($row);
		
		delete $self->data->{$id};
		
		return $self;
	}
	
	sub add_batch
	{
		my $self = shift;
		my $rows = shift;
		
		my @rows = @{$rows || []};
		return undef if !@rows;
		
		my $data  = $self->data;
		my $index = $self->index;
		my @keys  = @{ $self->db->{keys} };
		
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
			
			# return the value from the hash so the user gets the blessed DBM::Deep ref
			push @out, $self->data->{$row->{id}};
		}
		
		return \@out;
	}
	
	sub del_batch
	{
		my $self = shift;
		my $rows = shift;
		my @rows = @{$rows || []};
		return if !@rows;
		
		my $data  = $self->data;
		my $index = $self->index;
		my @keys  = @{ $self->db->{keys} };
		
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
		
		return $self;
	}
	
	sub _index_row
	{
		my $self = shift;
		my $row = shift;
		
		my $id = $row->{id};
		my $index = $self->index;
		my @keys  = @{ $self->db->{keys} };
		
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
		
		my $id = $row->{id};
		my $index = $self->index;
		my @keys  = @{ $self->db->{keys} };
		
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
		my @keys  = @{ $self->db->{keys} };
		
		# clear index
		$self->db->{idx} = {};
		
		# create hash for each key
		my $index = $self->index;
		$index->{$_} = {} foreach @keys;
		
		# index every row of data
		my @data  = values %{ $self->data };
		foreach my $row (@data)
		{
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
		return [ sort { $a->{$sort_key} <=> $b->{$sort_key} } @data ] if defined $sort_key;
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

		# If $force_index is true, then if $key was not in the original list of index keys,
		# we will automatically add it and build an index for that $key before returning
		# any results
		my $auto_index = $self->{auto_index};
		
		# The given key never indexed - add $key to the list of keys to index and rebuild the index
		$self->add_index_key($key) if !$self->index->{$key} && $auto_index;
		
		#print STDERR __PACKAGE__.": by_key: key='$key', val='$val'\n";
		#print_stack_trace() if !$val;
		
		# No values exist for this value for this key
		return wantarray ? () : undef if ! defined $self->index->{$key}->{$val};
		
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
