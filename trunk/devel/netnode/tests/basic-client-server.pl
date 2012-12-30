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
my $db_client_file = 'db.test-basic-client';
my $db_server_file = 'db.test-basic-server';

# Mute logging output
$HashNet::Util::Logging::LEVEL = 0;

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

	my $ch = HashNet::MP::ClientHandle->connect('localhost:'.$test_port, $node_info);


	#if(!$ch->send("Hello # $x to PID $$", to => $ch->uuid, flush => 0))
	my $orig_data = "Hello to PID $$";
	if(!$ch->send($orig_data, bcast => 1, flush => 0))
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
		is($msg->{data}, $orig_data, "Received original data");
	}
	else
	{
		#debug "$0: Did not receive any message\n";
		ok(0, "Did not receive any messages");
	}
	
	$ch->stop();
}

kill 15, $pid;
unlink($test_srv_cfg);
HashNet::MP::LocalDB->dump_db($db_client_file);
HashNet::MP::LocalDB->dump_db($db_server_file);


done_testing();

debug "$0: Done in $$, killed child $pid\n";

