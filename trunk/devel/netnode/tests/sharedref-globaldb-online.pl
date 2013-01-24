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
my $db_client_file1 = '/tmp/db.test-client1';
my $db_client_file2 = '/tmp/db.test-client2';
my $db_server_file = '/tmp/db.test-basic-server';

HashNet::MP::LocalDB->dump_db($db_client_file1);
HashNet::MP::LocalDB->dump_db($db_client_file2);
HashNet::MP::LocalDB->dump_db($db_server_file);

HashNet::MP::GlobalDB->delete_disk_cache($db_client_file1);
HashNet::MP::GlobalDB->delete_disk_cache($db_client_file2);
HashNet::MP::GlobalDB->delete_disk_cache($db_server_file);


# Mute logging output
$HashNet::Util::Logging::LEVEL = 0;
$HashNet::Util::Logging::ANSI_ENABLED = 1 if $HashNet::Util::Logging::LEVEL;

# The key we'll use
my $sh_key = "/shared/test-sharedref-globaldb";

# Just to cleanup debug output
$HashNet::MP::GlobalDB::OFFLINE_TX_ENABLED = 0;

# Another debug out cleanup
$HashNet::MP::SharedRef::LOCK_DEBUGOUT_PREFIX = "";




# The tests use this shared ref to sync testing
my $lock_ref = HashNet::MP::SharedRef->new(".test.synclock");

my $test_key = '/test/server_pid';

my $server_pid = fork;
if(!$server_pid)
{
	$0 = "$0 [Server]";
	trace "$0: Starting server thread\n";
	$HashNet::MP::LocalDB::DBFILE = $db_server_file;
	HashNet::MP::MessageHub->new(
		port        => $test_port,
		config_file => $test_srv_cfg
	);
}

my $client_pid = fork;
if(!$client_pid)
{
	$0 = "$0 [Put]";
	trace "$0: Locking $lock_ref (", $lock_ref->file, ")\n";
	$lock_ref->lock_file(30);
	#trace "$0: Lock acquired on $lock_ref\n";
	
	#print STDERR "# Waiting for server to start in fork $pid...\n";
	#sleep 1.1;
	#print STDERR "# Proceeding with test...\n";
	#trace "$0: Test proceding\n";
	
	$HashNet::MP::LocalDB::DBFILE = $db_client_file1;
	
	my $node_info = {
		uuid => '1509280a-5687-4a6b-acc8-bd58beaccbae',
		name => $0,
		type => 'client',
	};

	my $db = HashNet::MP::GlobalDB->new();
	
	my $ch;
	my $start = time;
	my $max_time = 60;
	sleep 0.5 while time - $start < $max_time and
	                !($ch = HashNet::MP::ClientHandle->connect('localhost:'.$test_port, $node_info));
	
	# Since the server config is empty, wait for the other client to connect and register as a new client, so
	# that when the GlobalDB broadcasts its TR, the server knows to send it to the other client
	#trace "$0: Sleep 1 in client 1\n\n\n\n"; 
	#sleep 1;
	
	# We're not testing anything that needs MSG_CLIENT_RECEIPTs right now, so turn them off just to clean up debugging output
	#$ch->{send_receipts} = 0 if $HashNet::Util::Logging::LEVEL;
	
	
	$db->set_client_handle($ch);
	
	my $shref = HashNet::MP::SharedRef->new($sh_key, gdb => $db);

	trace "$0: Client: putting /test/server_pid => $server_pid\n";

	trace "$0\n\n\n\n\n\n";
	
	$shref->update_begin;
	$shref->{$test_key} = $server_pid;
	$shref->update_end;
	
	trace "$0: Client put done, exiting\n";
	trace "$0\n\n\n\n\n\n";

	$lock_ref->unlock_file;
	
	exit;
}


{
	$0 = "$0 [Test]";
	#print STDERR "# Waiting for server to start in fork $pid...\n";
	sleep 2.0;
	#print STDERR "# Proceeding with test...\n";
	
	$HashNet::MP::LocalDB::DBFILE = $db_client_file2;
	
	my $node_info = {
		uuid => '81cfb18e-0b9c-4b1f-b9f9-58be6ffa8731',
		name => $0,
		type => 'client',
	};

	$lock_ref->lock_file(30);

	my $db = HashNet::MP::GlobalDB->new();
	
	my $ch;
	my $start = time;
	my $max_time = 60;
	sleep 0.5 while time - $start < $max_time and
	                !($ch = HashNet::MP::ClientHandle->connect('localhost:'.$test_port, $node_info));

	$db->set_client_handle($ch);
	
	#print "\n\n\n\n\n\n\n\n";
	trace "$0: Starting final test client (disk cache $db_client_file2)\n";

	my $shref = HashNet::MP::SharedRef->new($sh_key, gdb => $db);
	
	trace "$0: Getting $test_key\n";
	
	my $pid_t = $shref->{$test_key};
	
	trace "$0: Get finished, result: '$pid_t', expected: '$server_pid', match? ".($pid_t == $server_pid ? "Yes" : "No")."\n";
	
	is($pid_t, $server_pid, "Data retrieval");
	
	
	$lock_ref->unlock_file;
	$lock_ref->delete_file;
}


kill 15, $server_pid;
kill 15, $client_pid;
unlink($test_srv_cfg);
HashNet::MP::LocalDB->dump_db($db_client_file1);
HashNet::MP::LocalDB->dump_db($db_client_file2);
HashNet::MP::LocalDB->dump_db($db_server_file);

HashNet::MP::GlobalDB->delete_disk_cache($db_client_file1);
HashNet::MP::GlobalDB->delete_disk_cache($db_client_file2);
HashNet::MP::GlobalDB->delete_disk_cache($db_server_file);

done_testing();

trace "$0: Done in $$, killed server $server_pid, child $client_pid\n";
#kill 9, $$;
#exit;


