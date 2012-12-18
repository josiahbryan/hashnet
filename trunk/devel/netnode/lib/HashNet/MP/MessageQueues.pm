use common::sense;
{package HashNet::MP::MessageQueues;

	# base class of this module
	our @ISA = qw(Exporter);

	# Exporting by default
	our @EXPORT = qw(incoming_queue outgoing_queue msg_queue);
	# Exporting on demand basis.
	our @EXPORT_OK = qw();

	# Class Data
	my $MsgQueueData = {};

	sub msg_queue
	{
		my $self = $MsgQueueData;
		my $queue = shift;

		return  $self->{queues}->{$queue}->{ref} if
			$self->{queues}->{$queue}->{pid} == $$;

		#trace "SocketWorker: msg_queue($queue): (re)creating queue in pid $$\n";
		my $ref = HashNet::MP::LocalDB->indexed_handle('/queues/'.$queue);
		$self->{queues}->{$queue} = { ref => $ref, pid => $$ };
		return $ref;
	}

	sub incoming_queue { msg_queue('incoming') }
	sub outgoing_queue { msg_queue('outgoing') }

};
1;
