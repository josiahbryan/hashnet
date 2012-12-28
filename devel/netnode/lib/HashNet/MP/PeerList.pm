
{package HashNet::MP::PeerList;
	
	use common::sense;
		
	use HashNet::MP::LocalDB;
	use HashNet::MP::Peer;
	use HashNet::Util::Logging;
	
	use Data::Dumper;

	sub peers
	{
		my $class = shift;
		my $ignore_self_uuid = shift || 0;
		my $online_only = shift || 0;
		my $db = HashNet::MP::LocalDB->indexed_handle('/peers');
		my @list = @{ $db->list };
		@list = grep { $_->{uuid} ne $ignore_self_uuid } @list if $ignore_self_uuid;
		@list = grep { $_->{online} } @list if $online_only;
		return map { HashNet::MP::Peer->from_hash($_) } @list;
	}
	
	sub peers_by_type
	{
		my $class = shift;
		my $type = shift || 'hub';
		my $ignore_self_uuid = shift || 0;
		my $online_only = shift || 0;
		my $db = HashNet::MP::LocalDB->indexed_handle('/peers');
		my @list = $db->by_field( type => $type );
		@list = grep { $_->{uuid} ne $ignore_self_uuid } @list if $ignore_self_uuid;
		@list = grep { $_->{online} } @list if $online_only;
		return map { HashNet::MP::Peer->from_hash($_) } @list;
	}

	sub hubs    { shift->peers_by_type('hub',    @_) }
	sub clients { shift->peers_by_type('client', @_) }
	

	
	sub get_peer_by_uuid
	{
		my $class = shift;
		my $node_info = shift;
		my $uuid = ref $node_info eq 'HASH' ? $node_info->{uuid} : $node_info;
		
		return undef if !$uuid;

		#trace "PeerList: get_peer_by_uuid: UUID: '$uuid'\n";
		#trace "PeerList: DEBUG: node_info: ".Dumper($node_info);
		 
		my $db = HashNet::MP::LocalDB->indexed_handle('/peers');
		
		my $peer_data = $db->by_key(uuid => $uuid);
		if(!$peer_data)
		{
			$peer_data = $db->add_row({ uuid => $uuid }); # returns hash with 'id' field set
			#if !$peer_data;
			trace "PeerList: get_peer_by_uuid: uuid '$uuid' not found, new peer data inserted as id '$peer_data->{id}'\n";
		}

		#trace "PeerList: get_peer_by_uuid: Peer data for '$uuid' before merge keys: ".Dumper($peer_data);
		
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

	sub update_peer
	{
		my $class = shift;
		my $peer = shift;
		my $db = HashNet::MP::LocalDB->indexed_handle('/peers');
		$db->update_row($peer);
	}
};
1;