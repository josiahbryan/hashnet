#!/usr/bin/perl
use strict;
use warnings;

package HashNet::StorageEngine::TransactionRecord;
{
#	use base qw/Object::Event/;
	use Storable qw/freeze thaw/;
	use JSON::PP qw/encode_json decode_json/;
	use Time::HiRes qw/time/;
	
	use UUID::Generator::PurePerl;
	
	use MIME::Base64::Perl; # for encoding/decoding binary data
	
	use HashNet::StorageEngine::PeerServer; # for node_info->{uuid}
	use HashNet::Util::Logging;
	use Data::Dumper;
	
	my $ug = UUID::Generator::PurePerl->new();
	
	# Disable Base64 encoding for now because we're going to try freeze/thaw and POST instead of JSON encoding transactions
	our $ENABLE_BASE64_ENCODING = 0;
	
#public:
	sub TYPE_WRITE_BATCH() { 'TYPE_WRITE_BATCH' }
	sub TYPE_WRITE() { 'TYPE_WRITE' }
	sub TYPE_READ()  { 'TYPE_READ'  }
	sub MODE_SQL()   { 'MODE_SQL'   }
	sub MODE_KV()    { 'MODE_KV'    }

	sub new#($mode=[MODE_SQL|MODE_KV],$data_or_key,$data=undef,$type=[TYPE_READ|TYPE_WRITE])
	{
		my $class = shift;
		my $self = bless {}, $class; #$class->SUPER::new();

		my $mode = shift || MODE_KV;
		my $key  = shift || undef;
		my $data = shift || undef;
		my $type = shift || TYPE_WRITE;

		$self->{is_valid} = defined $key ? 1:0;

		$self->{mode} = $mode;
		$self->{type} = $type;
		$self->{key}  = $key;
		$self->{data} = $data;
		$self->{uuid} = $ug->generate_v1->as_string();
		$self->{timestamp} = time();
		# this is set by StorageEngine _push_tr() - it's relative to each node, but it IS loaded/saved by the to/from has methods
		$self->{rel_id} = undef;
		$self->{route_hist} = []; # list of hashes
			# Eash hash has:
			# 	- uuid	- host UUIDs where this transaction has been (HashNet::StorageEngine::PeerServer->node_info->{uuid})
			#	- ts	- timestamp received/generated at the host
		$self->{edit_num} = undef; # edit number to be propogated amongst all peers - we theorize it should stay in sync, testing to be done...
		
		$self->{local_timestamp} = time(); # for sequencing for pull peers
			# NOTE NOT stored by to_hash/from_hash

		return $self;
	};

	sub mode { shift->{mode}  }
	sub type { shift->{type}  }
	sub key  { shift->{key}   }
	sub data { shift->{data} }
	sub uuid { shift->{uuid} }
	sub timestamp { shift->{timestamp} }
	sub local_timestamp { shift->{local_timestamp} }
	sub is_valid { shift->{is_valid} }
	sub rel_id { shift->{rel_id} }
	sub merged_uuid_list { shift->{merged_uuid_list} || [] }
	sub edit_num { shift->{edit_num} }

	sub host_uuid()
	{
		HashNet::StorageEngine::PeerServer->node_info->{uuid}
# 		join('::',
# 			HashNet::StorageEngine::PeerServer->peer_port(),
# 			HashNet::StorageEngine::PeerServer->node_info->{uuid}
# 		);
	}
	
	# Update route history, done before transmitting
	sub update_route_history
	{
		my $self = shift;
		my $relid = shift;
		$relid = -1 if ! defined $relid;
		push @{$self->{route_hist}}, {
			uuid  => host_uuid(),
			ts    => time(),
			relid =>  $relid,
		};
	}
	
	sub update_route_history_uuid
	{
		my $self = shift;
		my $uuid = shift;
		my $relid = shift;
		$relid = -1 if ! defined $relid;
		if(!$uuid)
		{
			warn "update_route_history_uuid: No UUID given";
			return undef;
		}
		push @{$self->{route_hist}}, {
			uuid  => $uuid,
			ts    => time(),
			relid =>  $relid,
		};
	}
	
	sub has_been_here
	{
		my $self = shift;
		if($self eq __PACKAGE__)
		{
			$self = shift;
		}
		
		my $uuid = shift || host_uuid();
		my @hist = @{$self->{route_hist} || []};
		foreach my $hist (@hist)
		{
			return 1 if $hist->{uuid} eq $uuid;
		}
		return 0;
	}
	
	sub _dump_route_hist
	{
		my $self = shift;
		my $uuid = shift || host_uuid();
		my @hist = @{$self->{route_hist} || []};
		logmsg 'TRACE', "_dump_route_hist(): Host uuid: $uuid, tr uuid: ", $self->uuid, ": \n";
		foreach my $hist (@hist)
		{
			logmsg 'TRACE', "_dump_route_hist(): \t Host $hist->{uuid} at $hist->{ts}", ($hist->{uuid} eq $uuid ? " <== This Host" : ""), "\n";
		}
		logmsg 'TRACE', "_dump_route_hist(): --------- \n";
		return 0;
	}

	sub to_bytes
	{
		my $self = shift;
		return freeze($self->to_hash);
	}

	sub to_json
	{
		my $self = shift;
		return encode_json($self->to_hash);
	}

	sub to_hash
	{
		my $self = shift;
		my @hist;
		my @hist_tmp = @{ $self->{route_hist} || []};
		foreach my $tmp (@hist_tmp)
		{
			push @hist, { uuid => $tmp->{uuid}, ts => $tmp->{ts} };
		}
		my $hash = {
			mode	   => $self->{mode},
			key	   => $self->{key},
			
			# _clean_ref() creates a pure hash-/array-ref structure
			# from any blessed hash/arrayrefs such as from DBM::Deep
			# - necessary because JSON doesn't like blessed refs
			#data	   => _clean_ref($self->{data}),
			
			# Removed use of _clean_ref because we're going to try freeze/thaw instead of encode_json
			data	   => $self->{data},
			
			type	   => $self->{type},
			uuid	   => $self->{uuid},
			timestamp  => $self->{timestamp},
			rel_id     => $self->{rel_id},
			route_hist => \@hist,
			# Only created by HashNet::StorageEngine->merge_transactions(), and used by PeerServer when receiving a merged tx
			merged_uuid_list => $self->{merged_uuid_list},
			# set by StorageEngine in _put_peers and _put_local_batch, used (indirectly) by _put_local for received transactions
			edit_num => $self->{edit_num},
		};
		
		# Here we're trying to be "smarter" than the JSON module.
		# By default, JSON will encode binary data with escape sequences. For example, here's the start of a PNG image:
		#	PNG\r\n\u001a\n\u0000\u0000\u0000\rIHDR\u0000\u0000
		# However, for a 345-byte PNG image, the JSON equivelant is approx 950 bytes long, 
		# while a base64 encoding of the same data is only 467 bytes.
		# Therefore, for {data} elements that are NOT references AND contain unprintable (/[^\t\n\x20-x7e]/) characters, 
		# we base64 encode and add a flag to the hash telling the from_hash() routine to do appros decoding
		
		# Note that this is NOT relevant for storing in the transaction database, since DBM::Deep does it's own serliazation
		# of hashes (e.g. we don't use to_json for that storage) - however, we do this here since the transaction
		# doesn't know if the return from to_hash() is going to json or just being stored - so we are proactive here at a slight cost.
		 
		# Disabling for now - working on a better way of handling binary data
		if($ENABLE_BASE64_ENCODING)
		{
			$self->base64_encode($hash);
		}
		
		return $hash;
	}
	
	sub base64_encode
	{
		my $class = shift;
		my $hash  = shift;
		if(!ref($hash->{data}) && defined($hash->{data}) &&
			#$hash->{data} =~ /[^\t\n\x20-x7e]/)
			$hash->{data} =~ /[^[:print:]]/)
		{
			$hash->{data} = encode_base64($hash->{data});
			$hash->{data_base64} = 1;
		}
		elsif($hash->{type} eq TYPE_WRITE_BATCH)
		{
			my @batch = @{ $hash->{data} || {} };
			foreach my $item (@batch)
			{
				if(!ref($item->{val}) && defined($item->{val}) &&
					#$item->{val} =~ /[^\t\n\x20-x7e]/)
					$item->{val} =~ /[^[:print:]]/)
				{
					$item->{val} = encode_base64($item->{val});
					$item->{val_base64} = 1;
				}
			}
		}
		
		return $hash;
	}

	sub _clean_ref
	{
		my $ref = shift;
		return $ref if !ref($ref) || !$ref;
		if(ref $ref eq 'ARRAY' ||
		   ref $ref eq 'DBM::Deep::Array')
		{
			my @new_array;
			my @old_array = @$ref;
			foreach my $line (@old_array)
			{
				push @new_array, _clean_ref($line);
			}
			return \@new_array;
		}
		#elsif(ref $ref eq 'HASH' ||
		#      ref $ref eq 'DBM::Deep::Hash')
		else
		{
			my %new_hash;
			my %old_hash = %$ref;
			my @keys = keys %old_hash;
			foreach my $key (keys %old_hash)
			{
				$new_hash{$key} = _clean_ref($old_hash{$key});
			}
			return \%new_hash;
		}
		warn "TransactionRecord: _clean_ref($ref): Could not clean ref type '".ref($ref)."'";
		return $ref;
	}

	sub from_bytes
	{
		my $class = shift;
		my $bytes = shift;
		my $hash  = thaw($bytes);
		return $class->from_hash($hash);
	}

	sub from_json
	{
		my $class = shift;
		my $json = shift;
		my $hash = decode_json($json);
		return $class->from_hash($hash);
	}

	sub from_hash
	{
		my $class = shift;
		my $hash = shift;
		
		#trace "TransactionRecord: from_hash(): Dumper of hash: ",Dumper($hash);
		
		# See discussion in to_hash() on why base64 instead of relying on direct storage
# 		if($ENABLE_BASE64_ENCODING)
# 		{
			if($hash->{data_base64})
			{
				$hash->{data} = decode_base64($hash->{data});
				delete $hash->{data_base64};
			}
			# Check for base64 encoded data in the batch list
			elsif($hash->{type} eq TYPE_WRITE_BATCH)
			{
				my @batch = @{ $hash->{data} || {} };
				foreach my $item (@batch)
				{
					if($item->{val_base64})
					{
						$item->{val} = decode_base64($item->{val});
						delete $item->{val_base64};
					}
				}
			}
#		}
		
		my $obj = $class->new(
			$hash->{mode},
			$hash->{key},
			$hash->{data},
			$hash->{type},
		);
		$obj->{uuid}       = $hash->{uuid};
		$obj->{timestamp}  = $hash->{timestamp};
		$obj->{rel_id}     = $hash->{rel_id};
		$obj->{route_hist} = $hash->{route_hist};
		$obj->{merged_uuid_list} = $hash->{merged_uuid_list};
		$obj->{edit_num}   = $hash->{edit_num};
		
		return $obj;
	}
};

1;
