#!/usr/bin/perl

use strict;

use Test::More;

use common::sense;
use lib '../lib';
use lib 'lib';

use HashNet::MP::LocalDB;
use HashNet::Util::Logging;
use Time::HiRes qw/sleep/;

# Necessary for the stale lock to be detected
$SIG{CHLD} = 'IGNORE';

# Mute logging output
$HashNet::Util::Logging::LEVEL = 0;
#$HashNet::Util::Logging::ANSI_ENABLED = 1 if $HashNet::Util::Logging::LEVEL;

$HashNet::MP::LocalDB::DBFILE = "/tmp/test-stale-locks.db";

my $pid = fork;
if(!$pid)
{
	HashNet::MP::LocalDB->handle()->lock_file;
	HashNet::MP::LocalDB->indexed_handle('/test_table')->lock_file;
	
	trace "$0: lock_file called for on LocalDB\n";
	exit;
}
else
{
	sleep 0.5;
	kill 15, $pid;
	
	is(HashNet::MP::LocalDB::cleanup_stale_locks(), 2, "cleanup_stale_locks()");

	HashNet::MP::LocalDB->handle()->lock_file;

	is(HashNet::MP::LocalDB::cleanup_stale_locks(), 0, "cleanup_stale_locks() doesnt clobber valid lock");

	HashNet::MP::LocalDB->handle()->unlock_file;
	
}

done_testing();

kill 15, $pid;
HashNet::MP::LocalDB->dump_db();

END{
}
