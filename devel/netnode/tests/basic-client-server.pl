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

unlink($test_srv_cfg);
HashNet::MP::LocalDB->dump_db($db_client_file);
HashNet::MP::LocalDB->dump_db($db_server_file);


# Mute logging output
$HashNet::Util::Logging::LEVEL = 0;
$HashNet::Util::Logging::ANSI_ENABLED = 1 if $HashNet::Util::Logging::LEVEL;

my $pid = fork;
if(!$pid)
{
	$0 = "$0 [server]";
	$HashNet::MP::LocalDB::DBFILE = $db_server_file;
	HashNet::MP::MessageHub->new(
		port        => $test_port,
		config_file => $test_srv_cfg
	);
}
else
{
	$0 = "$0 [client]";
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
	$ch->{send_receipts} = 0 if $HashNet::Util::Logging::LEVEL;
	
	$ch->wait_for_start;

	trace "$0: Lock outgoing queue\n";
	#$ch->sw->outgoing_queue->lock_file;
	$ch->sw->outgoing_queue->begin_batch_update;
	
	my $orig_data = "Hello to PID $$";
	if(!$ch->send($orig_data, bcast => 1, flush => 0))
	{
		die "Unable to send message";
	}

	#my $len = 20;
	#trace "$0: Sleeping $len sec just to test\n";
	#sleep $len;
	
	#$ch->sw->outgoing_queue->unlock_file;
	trace "$0: Unlock outgoing queue\n";
	$ch->sw->outgoing_queue->end_batch_update;
	
	$ch->wait_for_send;
	$ch->wait_for_receive(timeout => 10);

	my @msgs = $ch->messages(0); # blocks [default 4 sec] until messages arrive, pass a false argument to not block

	if(@msgs)
	{
		#info "$0: Received msg '$_->{data}'\n" foreach @msgs;
		my $msg = shift @msgs;
		is($msg->{data}, $orig_data, "Received original data");
	}
	else
	{
		#debug "$0: Did not receive any message\n";
		ok(0, "Did not receive first message");
	}

#######

	my $att = "PID $$";
	if(!$ch->send($orig_data, _att => $att, bcast => 1, flush => 0))
	{
		die "Unable to send message";
	}

	$ch->wait_for_send;
	$ch->wait_for_receive;

	my @msgs = $ch->messages(0); # blocks [default 4 sec] until messages arrive, pass a false argument to not block

	if(@msgs)
	{
		#info "$0: Received msg '$_->{data}'\n" foreach @msgs;
		my $msg = shift @msgs;
		is($msg->{data}, $orig_data, "Orig data with attachment");
		is($msg->{_att}, $att, "Attachment transmitted");
	}
	else
	{
		#debug "$0: Did not receive any message\n";
		ok(0, "Did not receive attachment message");
	}
	
	$ch->stop();
}

done_testing();

kill 15, $pid;
unlink($test_srv_cfg);
HashNet::MP::LocalDB->dump_db($db_client_file);
HashNet::MP::LocalDB->dump_db($db_server_file);
debug "$0: Done in $$, killed child $pid\n";
