
{package HashNet::MP::SocketWorker;

	use common::sense;
	use base qw/HashNet::Util::MessageSocketBase/;
	use JSON qw/to_json from_json/;
	use Data::Dumper;
	
	use Time::HiRes qw/time/;
	
	use HashNet::MP::PeerList;
	use HashNet::MP::LocalDB;
	
	use HashNet::Util::CleanRef;
	
	use UUID::Generator::PurePerl; # for use in gen_node_info
	
	sub MSG_NODE_INFO	{ 'MSG_NODE_INFO' }
	sub MSG_INTERNAL_ERROR	{ 'MSG_INTERNAL_ERROR' }
	sub MSG_ACK		{ 'MSG_ACK' }
	sub MSG_UNKNOWN		{ 'MSG_UNKNOWN' }
	
	# Simple utility method to auto-generate the node_info structure based on $0
	my $UUID_GEN = UUID::Generator::PurePerl->new(); 
	sub gen_node_info
	{
	
		my $dbh = HashNet::MP::LocalDB->handle;
		my $node_info = $dbh->{auto_clients}->{$0};
		if(!$node_info)
		{
			$node_info->{name} = $0;
			$node_info->{uuid} = $UUID_GEN->generate_v1->as_string();
			$dbh->{auto_clients}->{$0} = $node_info;
		}
		
		#print STDERR "Debug: gen_node_info: node_info:".Dumper($node_info);
		
		return $node_info;
	}
	
	sub new
	{
		my $class = shift;
		
		# Allow single argument of $socket, assume no forking
		if(@_ == 1)
		{
			@_ = (
				sock    => $_[0],
				no_fork => 1
			);
		}
		
		my %opts = @_;
		
		# If we DON'T set auto_start to 0,
		# then ::new() may never return if
		# the caller set {no_fork} to a TRUE
		# value - ::new() would call start()
		# which would go right into a process_loop()
		# and we would never get the stack back from
		# new() until process_loop() ends.
		# By setting auto_start() to 0, we get the
		# chance to do other things before
		# 'risking' loosing the process by calling
		# start() at the end of our new()
		my $old_auto_start = $opts{auto_start}; 
		$opts{auto_start} = 0;
		
		# Auto-generate node_info as needed
		$opts{node_info} = $class->gen_node_info if !$opts{node_info};
		
		my $self = $class->SUPER::new(%opts);
		
		#
		# Do any other setup with $self here
		#
		
		# Allow the caller to call start() if desired
		$self->start unless defined $old_auto_start && !$old_auto_start;
		 
		return $self;
	}
	
	sub bad_message_handler
	{
		my $self    = shift;
		my $bad_msg = shift;
		my $error   = shift;
		
		print STDERR "bad_message_handler: '$error' (bad_msg: $bad_msg)\n";
		$self->send_message({ msg => MSG_INTERNAL_ERROR, error => $error, bad_msg => $bad_msg });
	}
	
	sub connect_handler
	{
		my $self = shift;
		
		$self->send_message({ msg => MSG_NODE_INFO, node_info => $self->{node_info} });
	}
	
	sub disconnect_handler
	{
		my $self = shift;
		
		#print STDERR "SocketWorker: disconnect_handler: peer: $self->{peer}\n";
		$self->{peer}->set_online(0) if $self->{peer};
	}
	
	sub dispatch_message
	{
		my $self = shift;
		my $hash = shift;
		my $second_part = shift;
		
		#print STDERR "dispatch_message: hash: ".Dumper($hash)."\n";
		
		#$self->send_message({ received => $hash });
		my $msg = $hash->{msg};
		
		if($msg eq MSG_ACK)
		{
			# Just ignore ACKs for now
		}
		elsif($msg eq MSG_NODE_INFO)
		{
			my $node_info = $hash->{node_info};
			print STDERR "dispatch_msg: Received MSG_NODE_INFO for remote node '$node_info->{name}'\n";
			$self->{remote_node_info} = $node_info;
			
			$self->send_message({ msg => MSG_ACK, ack_msg => MSG_NODE_INFO, text => "Hello, $node_info->{name}" });
			
			my $peer;
			if($self->{peer})
			{
				$peer = $self->peer;
				$peer->merge_keys($node_info);
			}
			else
			{
				$peer = HashNet::MP::PeerList->get_peer_by_uuid($node_info);
				$self->{peer} = $peer;
			}
			
			$peer->set_online(1);
		}
		else
		{
			#print STDERR "dispatch_msg: Unknown msg received: $msg\n";
			#$self->send_message({ msg => MSG_UNKNOWN, text => "Unknown message type '$msg'" });
			my $row = { time => time(), peer => $self->peer->uuid, dest => $hash->{dest}, msg => $msg, hash => $hash };
			$self->incoming_queue->add_row($row);
			print STDERR __PACKAGE__.": dispatch_msg: New incoming row added to queue: ".Dumper($row);
		}
	}
	
	sub peer { shift->{peer} }
	
	sub msg_queue
	{
		my $self = shift;
		my $queue = shift;
		
		return $self->{queues}->{$queue} if defined $self->{queues}->{$queue};
		
		my $ref = HashNet::MP::LocalDB->indexed_handle('/queues/'.$queue);
		$self->{queues}->{$queue} = $ref;
		return $ref;
	}
	
	sub incoming_queue { shift->msg_queue('incoming') }
	sub outgoing_queue { shift->msg_queue('outgoing') }
	
	# Returns a list of pending messages to send using send_message() in process_loop
	use Data::Dumper;
	sub pending_messages
	{
		my $self = shift;
		my $queue = $self->outgoing_queue;
		#my @list1 = $queue->by_field({ dest => $self->peer->uuid });
		#my @list2 = $queue->by_field({ dest => '*' });
		#my @list = (@list1, @list2);
		return () if !$self->peer;
		my $uuid = $self->peer->uuid;
		my @list = $queue->by_field(dest => $uuid);
		@list = sort { $a->time cmp $b->time } @list;
		print STDERR __PACKAGE__.": pending_messages: Found ".scalar(@list)." messages for peer {$uuid}\n";
		print STDERR Dumper(\@list) if @list;
		
		my @return_list = map { HashNet::Util::CleanRef->clean_ref($_->{hash}) } @list;
		
		$queue->del_batch(\@list);
		return @return_list;
	}
};

1;
