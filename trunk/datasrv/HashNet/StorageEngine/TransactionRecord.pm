#!/usr/bin/perl
use strict;
use warnings;

package HashNet::StorageEngine::TransactionRecord;
{
	use base qw/Object::Event/;
	use Storable qw/freeze thaw/;
	use JSON::PP qw/encode_json decode_json/;
	use Time::HiRes qw/time/;
	
	use UUID::Generator::PurePerl;
	
	use HashNet::StorageEngine::PeerServer; # for node_info->{uuid}
	use HashNet::Logging;
	
	my $ug = UUID::Generator::PurePerl->new();
	
#public:
	sub TYPE_WRITE() { 'TYPE_WRITE' }
	sub TYPE_READ()  { 'TYPE_READ'  }
	sub MODE_SQL()   { 'MODE_SQL'   }
	sub MODE_KV()    { 'MODE_KV'    }

	sub new#($mode=[MODE_SQL|MODE_KV],$data_or_key,$data=undef,$type=[TYPE_READ|TYPE_WRITE])
	{
		my $class = shift;
		my $self = $class->SUPER::new();

		my $mode = shift || MODE_KV;
		my $key  = shift || undef;
		my $data = shift || undef;
		my $type = shift || TYPE_WRITE;

		$self->{is_valid} =
			$mode eq MODE_KV  ? $key && $data :
			$mode eq MODE_SQL ? $key
			: 0;

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
		push @{$self->{route_hist}}, {
			uuid => host_uuid(),
			ts   => time(),
		};
	}
	
	sub has_been_here
	{
		my $self = shift;
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
		return {
			mode	=> $self->{mode},
			key	=> $self->{key},
			data	=> $self->{data},
			type	=> $self->{type},
			uuid	=> $self->{uuid},
			timestamp => $self->{timestamp},
			rel_id  => $self->{rel_id},
			route_hist => \@hist,
		}
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
		my $obj = $class->new(
			$hash->{mode},
			$hash->{key},
			$hash->{data},
			$hash->{type},
		);
		$obj->{uuid}      = $hash->{uuid};
		$obj->{timestamp} = $hash->{timestamp};
		$obj->{rel_id}    = $hash->{rel_id};
		$obj->{route_hist} = $hash->{route_hist};
		return $obj;
	}
};
