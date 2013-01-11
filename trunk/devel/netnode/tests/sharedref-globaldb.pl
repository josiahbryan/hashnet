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
my $db_client_file = 'db.test-client';
my $db_server_file = 'db.test-basic-server';

HashNet::MP::LocalDB->dump_db($db_client_file);
HashNet::MP::LocalDB->dump_db($db_server_file);

HashNet::MP::GlobalDB->delete_disk_cache($db_client_file);
HashNet::MP::GlobalDB->delete_disk_cache($db_server_file);

# Mute logging output
$HashNet::Util::Logging::LEVEL = 0;
$HashNet::Util::Logging::ANSI_ENABLED = 1 if $HashNet::Util::Logging::LEVEL;

# The tests use this shared ref to sync testing
#my $lock_ref = HashNet::MP::SharedRef->new();

my $server_pid = fork;
if(!$server_pid)
{
	trace "$0: Starting server thread\n";
	$HashNet::MP::LocalDB::DBFILE = $db_server_file;
	HashNet::MP::MessageHub->new(
		port        => $test_port,
		config_file => $test_srv_cfg
	);
}

#print STDERR "# Waiting for server to start in fork $pid...\n";
sleep 2.0;
#print STDERR "# Proceeding with test...\n";
	
$HashNet::MP::LocalDB::DBFILE = $db_client_file;

my $node_info = {
	uuid => '81cfb18e-0b9c-4b1f-b9f9-58be6ffa8731',
	name => $0,
	type => 'client',
};

#$lock_ref->lock_file;

my $ch;
my $start = time;
my $max_time = 60;
sleep 0.5 while time - $start < $max_time and
		!($ch = HashNet::MP::ClientHandle->connect('localhost:'.$test_port, $node_info));

my $db = HashNet::MP::GlobalDB->new($ch);

ok(1);


# $lock_ref->unlock_file;
# $lock_ref->delete_file;


kill 15, $server_pid;
unlink($test_srv_cfg);
HashNet::MP::LocalDB->dump_db($db_client_file);
HashNet::MP::LocalDB->dump_db($db_server_file);

HashNet::MP::GlobalDB->delete_disk_cache($db_client_file);
HashNet::MP::GlobalDB->delete_disk_cache($db_server_file);

done_testing();

trace "$0: Done in $$, killed server $server_pid\n";
#kill 9, $$;
#exit;


