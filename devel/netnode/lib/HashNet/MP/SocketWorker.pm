
{package HashNet::MP::SocketWorker;

	use common::sense;
	use base qw/HashNet::Util::MessageSocketBase/;
	use JSON qw/to_json from_json/;
	use Data::Dumper;
	
	use Time::HiRes qw/time/;

	use Carp qw/carp croak/;
	
	use HashNet::MP::PeerList;
	use HashNet::MP::LocalDB;
	
	use HashNet::Util::CleanRef;
	
	use UUID::Generator::PurePerl; # for use in gen_node_info
	
	sub MSG_NODE_INFO	{ 'MSG_NODE_INFO' }
	sub MSG_INTERNAL_ERROR	{ 'MSG_INTERNAL_ERROR' }
	sub MSG_ACK		{ 'MSG_ACK' }
	sub MSG_USER		{ 'MSG_USER' }
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

	sub node_info { shift->{node_info} }

	sub create_envelope
	{
		my $self = shift;
		my $data = shift;

		@_ = %{ $_[0] || {} } if @_ == 1 && ref $_[0] eq 'HASH';

		@_ =  ( to => $_[0] ) if @_ == 1;
		
		my %opts = @_;

		if(!$opts{to} && $self->peer)
		{
			$opts{to} = $self->peer->uuid;
		}

		if(!$opts{to})
		{
			Carp::cluck "create_envelope: No destination given (either no to=>X, no 2nd arg, or no self->peer), therefore no envelope created";
			return undef;
		}

		if(!$opts{from})
		{
			$opts{from} = $self->node_info->{uuid};
		}

		$opts{hist} = [] if !$opts{hist};

		push @{$opts{hist}},
		[{
			from => $opts{from}, #$self->node_info->{uuid},
			to   => $opts{nxthop} || $opts{to},
			time => time(),
		}];
		

		my $env =
		{
			time	=> time(),
			uuid	=> $opts{uuid} || $UUID_GEN->generate_v1->as_string(),
			# From is the hub/client where this envelope originated
			from    => $opts{from},
			# To is the hub/client where this envelope is destined
			to	=> $opts{to},
			# Nxthop is the next hub/client this envelope is destined for
			nxthop	=> $opts{nxthop} || $opts{to},
			# If bcast is true, the next hub that gets this envelope
			# will copy it and broadcast it to each of its hubs/clients
			bcast	=> $opts{bcast} || 0,
			# If false, the hub will not store it if the client/hub is currently offline - just drops the envelope
			sfwd	=> defined $opts{sfwd} ? $opts{sfwd} : 1, # store n forward
			# Type is only relevant for internal types to SocketWorker - MSG_USER are just put into the incoming queue for the hub to route
			type	=> $opts{type} || MSG_USER,
			# Data is the actual content of the message
			data	=> $data,
			# History of where this envelope/data has been
			hist	=> $opts{hist},
		};

		return $env;
	}
	
	sub connect_handler
	{
		my $self = shift;
		
		$self->send_message($self->create_envelope($self->{node_info}, to => '*', type => MSG_NODE_INFO));
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
		my $envelope = shift;
		my $second_part = shift;
		
		#print STDERR "dispatch_message: envelope: ".Dumper($envelope)."\n";
		
		#$self->send_message({ received => $envelope });
		my $msg_type = $envelope->{type};
		
		if($msg_type eq MSG_ACK)
		{
			# Just ignore ACKs for now
		}
		elsif($msg_type eq MSG_NODE_INFO)
		{
			my $node_info = $envelope->{data};
			print STDERR "dispatch_msg: Received MSG_NODE_INFO for remote node '$node_info->{name}'\n";

			$self->{remote_node_info} = $node_info;
			
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

			$self->send_message($self->create_envelope({ack_msg => MSG_NODE_INFO, text => "Hello, $node_info->{name}" }, type => MSG_ACK));
		}
		else
		{
			$self->incoming_queue->add_row($envelope);
			print STDERR __PACKAGE__.": dispatch_msg: New incoming envelope added to queue: ".Dumper($envelope);
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
		return () if !$self->peer;

		my $uuid  = $self->peer->uuid;
		my $queue = $self->outgoing_queue;
		my @list  = $queue->by_field(nxthop => $uuid);
		@list = sort { $a->time cmp $b->time } @list;

		print STDERR __PACKAGE__.": pending_messages: Found ".scalar(@list)." messages for peer {$uuid}\n";
		print STDERR Dumper(\@list) if @list;
		
		my @return_list = map { clean_ref($_->{hash}) } @list;
		
		$queue->del_batch(\@list);
		return @return_list;
	}
};

1;
