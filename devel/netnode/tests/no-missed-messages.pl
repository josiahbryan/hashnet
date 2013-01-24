#!/usr/bin/perl

use Test::More;

use common::sense;
use lib '../lib';
use lib 'lib';

use Time::HiRes qw/time sleep/;
use HashNet::MP::MessageHub;
use HashNet::MP::SocketWorker;
use HashNet::MP::LocalDB;
use HashNet::MP::ClientHandle;
use HashNet::Util::Logging;

my $test_port = 82814;
my $test_srv_cfg = 'test-basic-server.conf';
my $db_client_file = '/tmp/db.test-basic-client';
my $db_server_file = '/tmp/db.test-basic-server';

HashNet::MP::LocalDB->dump_db($db_client_file);
HashNet::MP::LocalDB->dump_db($db_server_file);

# Mute logging output
$HashNet::Util::Logging::LEVEL = 0;
$HashNet::Util::Logging::ANSI_ENABLED = 1 if $HashNet::Util::Logging::LEVEL;

my $pid = fork;
if(!$pid)
{
	$HashNet::MP::LocalDB::DBFILE = $db_server_file;
	HashNet::MP::MessageHub->new(
		port        => $test_port,
		config_file => $test_srv_cfg
	);
}
else
{
	#print STDERR "# Waiting for server to start in fork $pid...\n";
	sleep 1.1;
	#print STDERR "# Proceeding with test...\n";
	
	$HashNet::MP::LocalDB::DBFILE = $db_client_file;
	
	my $node_info = {
		uuid => '1509280a-5687-4a6b-acc8-bd58beaccbae',
		name => $0,
		type => 'client',
	};

	my $ch;
	my $start = time;
	my $max_time = 60;
	sleep 0.5 while time - $start < $max_time and
	                !($ch = HashNet::MP::ClientHandle->connect('localhost:'.$test_port, $node_info));

	# We're not testing anything that needs MSG_CLIENT_RECEIPTs right now, so turn them off just to clean up debugging output
	#$ch->{send_receipts} = 0 if $HashNet::Util::Logging::LEVEL;
	
	$ch->wait_for_start;

	my $num_msgs = 100; #$HashNet::Util::Logging::LEVEL ? 1000 : 100;
	my $att_size = 1024; #024 * 8;
	trace "$0: Lock outgoing queue\n";
	#$ch->sw->outgoing_queue->lock_file;
	$ch->sw->outgoing_queue->begin_batch_update;
	$ch->send($_, bcast => 1, flush => 0, _att => $_ x ( $att_size / length($_) ) ) for 1..$num_msgs;
	#$ch->send($_, bcast => 1, flush => 0, _att => $_) for 1..$num_msgs;

	trace "$0: Unlock outgoing queue\n";
	$ch->sw->outgoing_queue->end_batch_update;
	#$ch->sw->outgoing_queue->unlock_file;
	
	$ch->wait_for_send;
	#warn "All sent, waiting for rx";
	$ch->wait_for_receive(msgs => $num_msgs, timeout => $num_msgs / 10); # 2nd arg is seconds, .1 sec per msg

	my @msgs = $ch->messages(0); # blocks [default 4 sec] until messages arrive, pass a false argument to not block

	if(@msgs)
	{
		is($msgs[$_]->{data},  $_ + 1, "Msg ".($_+1)." OK") for 0..$#msgs;
		is($msgs[$_]->{_att}, ($_ + 1) x ($att_size / length ($_ + 1)), "Attachment ".($_+1)." OK") for 0..$#msgs;
		
		info "$0: Received msg '$_->{data}'\n" foreach @msgs;
		@msgs = sort { $a->{data} <=> $b->{data} } @msgs;
		my $msg = $msgs[$#msgs];

		is($msg->{data},   $num_msgs, "Received proper data");
		is($msg->{_att},   $num_msgs x ( $att_size / length($num_msgs) ), "Received proper attachment");
		warn Dumper($msg->{data}) if ref $msg->{data}; # last test would have failed if ref, so add debug info
		
		is(scalar(@msgs), $num_msgs, "Received correct numer of messages");
	}
	else
	{
		#debug "$0: Did not receive any message\n";
		ok(0, "Did not receive any messages");
	}

	$ch->stop();
}

#warn "Test done";
done_testing();

#END {
kill 15, $pid;
unlink($test_srv_cfg);
HashNet::MP::LocalDB->dump_db($db_client_file);
HashNet::MP::LocalDB->dump_db($db_server_file);

debug "$0: Done in $$, killed child $pid\n";
#}

