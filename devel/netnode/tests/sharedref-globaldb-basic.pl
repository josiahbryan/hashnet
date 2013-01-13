#!/usr/bin/perl

use Test::More;

use common::sense;
use lib '../lib';
use lib 'lib';

use Time::HiRes qw/time sleep/;
use HashNet::MP::SharedRef;
use HashNet::MP::GlobalDB;
use HashNet::Util::Logging;

$SIG{CHLD} = 'IGNORE';

my $db_file = 'db.gdbshrefbasic';
$HashNet::MP::LocalDB::DBFILE = ".$db_file";

HashNet::MP::LocalDB->dump_db($db_file);
HashNet::MP::GlobalDB->delete_disk_cache($db_file);

# Mute logging output
$HashNet::Util::Logging::LEVEL = 0; #-t STDIN ? 999 : 0;
$HashNet::Util::Logging::ANSI_ENABLED = 1 if $HashNet::Util::Logging::LEVEL;

# Just to cleanup debug output
$HashNet::MP::GlobalDB::OFFLINE_TX_ENABLED = 0;

# Another debug out cleanup
$HashNet::MP::SharedRef::LOCK_DEBUGOUT_PREFIX = "";

my $gdb = HashNet::MP::GlobalDB->new(db_root => $db_file);

my $sh_key = "/shared/$0";
my $shref = HashNet::MP::SharedRef->new($sh_key, gdb => $gdb);

is($shref->file, $sh_key, "file() returns '$sh_key'");
is($shref->gdb,  $gdb,    "gdb() returns $gdb");
is($shref->data, $shref,  "data() returns $shref");

my $test_key = 'test';
my $test_val = $$;

# Test set_data()
$shref->set_data({ $test_key => $test_val });
is($shref->{$test_key}, $test_val, "set_data() stored '$test_key' as '$test_val'");
is($gdb->get($sh_key)->{$test_key}, $test_val, "set_data() auto-comitted into GlobalDB");

# Test locking (just uses same test code from sharedref-forked-locking.pl)
my $pid = fork;
if($pid == 0)
{
	# in child
	trace "Child forked\n";
	if($shref->lock_file)
	{
		#ok(1, "Child locked file");
		$shref->load_changes;
		my $len = 1;
		trace "Child: File locked, sleeping $len sec\n";
		sleep $len;
		$shref->{test} = $$;
		trace "Child: Sleep done, set {test} to $$\n";
		$shref->save_data;
		$shref->unlock_file;
		trace "Child: File saved and unlocked\n";
	}
	else
	{
		trace "Child: Unable to lock file\n";
		ok(0, "Lock file in child");
	}
	exit;
}
else
{
	my $len = .25;
	trace "Parent fork, waiting $len sec to give child chance to lock\n";
	sleep $len;
	trace "Parent: Attempting to lock\n";
	if($shref->lock_file)
	{
		ok(1, "Parent locked file");
		trace "Parent: File locked, testing data\n";
		is($shref->_cache_dirty, 1, "_cache_dirty() true");
		$shref->load_changes;
		trace "Parent: PID from file: $shref->{test}, real child: $pid\n";
		is($shref->{test}, $pid, "Load child PID from file");
		$shref->unlock_file;
	}
	else
	{
		trace "Parent: unable to lock file\n";
		ok(0, "Lock file in parent");
	}
}

# Lock tests from sharedref.pl
ok($shref->lock_file,      "Lock file");
is($shref->lock_file,   2, "Lock file again");
is($shref->unlock_file, 2, "Unlock file");
is($shref->unlock_file, 1, "Unlock file (really)");
is($shref->lock_file,   1, "Lock file after unlock");
ok($shref->unlock_file,    "Unlock file again");

# TODO: test 'fail on updated' mode


HashNet::MP::LocalDB->dump_db($db_file);
HashNet::MP::GlobalDB->delete_disk_cache($db_file);

done_testing();

trace "$0: Done in $$\n";
