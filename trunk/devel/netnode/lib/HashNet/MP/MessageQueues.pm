use common::sense;
{package HashNet::MP::MessageQueues;

	# base class of this module
	our @ISA = qw(Exporter);

	# Exporting by default
	our @EXPORT = qw(incoming_queue outgoing_queue msg_queue pending_messages outgoing incoming);
	# Exporting on demand basis.
	our @EXPORT_OK = qw();

	use HashNet::Util::CleanRef;
	use HashNet::Util::Logging;
	use HashNet::MP::LocalDB;

	# Class Data
	my $MsgQueueData = {};

	sub msg_queue
	{
		my $self = $MsgQueueData;
		my $queue = shift;

		return  $self->{queues}->{$queue} if defined #->{ref} if
			$self->{queues}->{$queue};   #->{pid} == $$;

		#trace "SocketWorker: msg_queue($queue): (re)creating queue in pid $$\n";
		my $ref = HashNet::MP::LocalDB->indexed_handle('/queues/'.$queue);

# 		if($ref->lock_file)
# 		{
# 			# Setup the index as needed
# 			$ref->add_index_key(qw/uuid nxthop to type/);
# 
# 			$ref->unlock_file;
# 		}
		
		$self->{queues}->{$queue} = $ref; #{ ref => $ref, pid => $$ };
		return $ref;
	}

	sub outgoing() { 'outgoing' }
	sub incoming() { 'incoming' }

	sub incoming_queue { msg_queue(incoming) }
	sub outgoing_queue { msg_queue(outgoing) }

	sub pending_messages
	{
		shift if $_[0] eq __PACKAGE__;
		#return () if @_ < 2;
		if(@_ == 2)
		{
			my ($queue_idx,$uuid) = @_;
			my ($x,$y) = split /[:\s]/, $queue_idx;
			@_ = ($x,$y,$uuid);
		}
		
		my $queue_name = shift;
		my $idx_key    = shift;
		my $uuid       = shift;

		my %opts       = @_;
		my $no_del     = $opts{no_del} || 0;

		if(!ref $queue_name)
		{
			$queue_name = 'outgoing' if $queue_name eq 'out' || $queue_name eq 'tx';
			$queue_name = 'incoming' if $queue_name eq 'in'  || $queue_name eq 'rx';
		}

		my @return_list;
		my $queue = ref $queue_name ? $queue_name : msg_queue($queue_name);
		if($queue->lock_file)
		{
			
			my @list  = $idx_key && $uuid ? $queue->by_key($idx_key => $uuid) : @{ $queue->list || [] };
			#return () if !@list;
			if(!@list)
			{
				$queue->unlock_file;
				return ();
			}
			
			@list = sort { $a->{time} cmp $b->{time} } @list;
	
			#trace "SocketWorker: pending_messages: Found ".scalar(@list)." messages for peer {$uuid}\n" if @list;
			#use Data::Dumper;
			#print STDERR Dumper(\@list) if @list && ref $queue_name;
			#print STDERR Dumper($self->peer);
	
			@return_list = map { clean_ref($_) } grep { defined $_ } @list;
	
			$queue->del_batch(\@list) unless $no_del;
	
			$queue->unlock_file;
		}
		else
		{
			trace "MessageQueues: pending_messages(): Failed to lock '$queue_name' queue, returning empty list\n";
			return ();
		}
		#print STDERR Dumper(\@return_list) if @return_list;
		return @return_list;
	}

};
1;
