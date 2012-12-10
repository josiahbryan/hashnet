
{package HashNet::MP::PeerList;
	
	use common::sense;
		
	use HashNet::MP::LocalDB;
	use HashNet::MP::Peer;
	
	use Data::Dumper;
	
	sub get_peer_by_uuid
	{
		my $class = shift;
		my $node_info = shift;
		my $uuid = ref $node_info eq 'HASH' ? $node_info->{uuid} : $node_info;
		
		return undef if !$uuid;
		 
		my $db = HashNet::MP::LocalDB->indexed_handle('/peers');
		
		my $peer_data = $db->by_key(uuid => $uuid);
		$peer_data = $db->add_row({ uuid => $uuid }) # returns hash blessed into DBM::Deep
			if !$peer_data;
		
		#print STDERR "get_peer: peers: ".Dumper($db->{peers});
		#print STDERR "PeerList: get_peer: node_info: ".Dumper($node_info);
		
		my $peer = HashNet::MP::Peer->from_hash($peer_data);
		$peer->merge_keys($node_info) if ref $node_info eq 'HASH';
		return $peer;
	}
	
	sub get_peer_by_host
	{
		my $class = shift;
		my $node_info = shift;
		my $host = ref $node_info eq 'HASH' ? $node_info->{host} : $node_info;
		
		return undef if !$host;
		 
		my $db = HashNet::MP::LocalDB->indexed_handle('/peers');
		
		my $peer_data = $db->by_key(host => $host);
		$peer_data = $db->add_row({ host => $host }) # returns hash blessed into DBM::Deep
			if !$peer_data;
		
		my $peer = HashNet::MP::Peer->from_hash($peer_data);
		$peer->merge_keys($node_info) if ref $node_info eq 'HASH';
		return $peer;
	}
};
1;