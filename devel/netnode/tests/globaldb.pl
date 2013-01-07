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

$SIG{CHLD} = 'IGNORE';

my $test_port = 82814;
my $test_srv_cfg = 'test-basic-server.conf';
my $db_client_file1 = 'db.test-client1';
my $db_client_file2 = 'db.test-client2';
my $db_server_file = 'db.test-basic-server';

HashNet::MP::LocalDB->dump_db($db_client_file1);
HashNet::MP::LocalDB->dump_db($db_client_file2);
HashNet::MP::LocalDB->dump_db($db_server_file);

# Mute logging output
$HashNet::Util::Logging::LEVEL = 0;
$HashNet::Util::Logging::ANSI_ENABLED = 1 if $HashNet::Util::Logging::LEVEL;

my $server_pid = fork;
if(!$server_pid)
{
	$HashNet::MP::LocalDB::DBFILE = $db_server_file;
	HashNet::MP::MessageHub->new(
		port        => $test_port,
		config_file => $test_srv_cfg
	);
}

my $client_pid = fork;
if(!$client_pid)
{
	#print STDERR "# Waiting for server to start in fork $pid...\n";
	sleep 2.1;
	#print STDERR "# Proceeding with test...\n";
	
	$HashNet::MP::LocalDB::DBFILE = $db_client_file1;
	
	my $node_info = {
		uuid => '1509280a-5687-4a6b-acc8-bd58beaccbae',
		name => $0,
		type => 'client',
	};

	my $ch = HashNet::MP::ClientHandle->connect('localhost:'.$test_port, $node_info);
	
	# Since the server config is empty, wait for the other client to connect and register as a new client, so
	# that when the GlobalDB broadcasts its TR, the server knows to send it to the other client
	trace "$0: Sleep 1 in client 1\n\n\n\n"; 
	sleep 1;
	
	# We're not testing anything that needs MSG_CLIENT_RECEIPTs right now, so turn them off just to clean up debugging output
	#$ch->{send_receipts} = 0 if $HashNet::Util::Logging::LEVEL;
	
	my $db = HashNet::MP::GlobalDB->new(sw => $ch->sw);

	$db->put('/test/server_pid' => $server_pid);

	$ch->stop();
	
	exit;
}


{
	#print STDERR "# Waiting for server to start in fork $pid...\n";
	sleep .1;
	#print STDERR "# Proceeding with test...\n";
	
	$HashNet::MP::LocalDB::DBFILE = $db_client_file1;
	
	my $node_info = {
		uuid => '81cfb18e-0b9c-4b1f-b9f9-58be6ffa8731',
		name => $0,
		type => 'client',
	};

	sleep 2.1;

	my $ch = HashNet::MP::ClientHandle->connect('localhost:'.$test_port, $node_info);
	
	# We're not testing anything that needs MSG_CLIENT_RECEIPTs right now, so turn them off just to clean up debugging output
	#$ch->{send_receipts} = 0 if $HashNet::Util::Logging::LEVEL;
	
	my $db = HashNet::MP::GlobalDB->new(sw => $ch->sw);
	
	# Wait for the client fork to have time to send the message
	trace "$0: Sleep 2 in test fork\n\n\n\n";
	sleep 2;

	my $pid_t = $db->get('/test/server_pid');
	is($pid_t, $server_pid, "Data retrieval");

 	$ch->stop();
}


kill 15, $server_pid;
kill 15, $client_pid;
unlink($test_srv_cfg);
HashNet::MP::LocalDB->dump_db($db_client_file1);
HashNet::MP::LocalDB->dump_db($db_client_file2);
HashNet::MP::LocalDB->dump_db($db_server_file);


done_testing();

trace "$0: Done in $$, killed server $server_pid, child $client_pid\n";
#kill 9, $$;
#exit;


