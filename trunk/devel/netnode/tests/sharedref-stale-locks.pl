#!/usr/bin/perl

use strict;

use Test::More;

use common::sense;
use lib '../lib';
use lib 'lib';

use HashNet::MP::SharedRef;
use HashNet::MP::LocalDB;
use HashNet::Util::Logging;
use Time::HiRes qw/sleep/;

# Necessary for the stale lock to be detected
$SIG{CHLD} = 'IGNORE';

# Mute logging output
#$HashNet::Util::Logging::LEVEL = 0;
$HashNet::Util::Logging::ANSI_ENABLED = 1 if $HashNet::Util::Logging::LEVEL;

$HashNet::MP::LocalDB::DBFILE = "$0.db";

my $ref = HashNet::MP::SharedRef->new();

my $pid = fork;
if(!$pid)
{
	$ref->lock_file();
	
	my $h = HashNet::MP::LocalDB->handle();
	my $h2 = HashNet::MP::LocalDB->indexed_handle('/test_table');
	
	#$h->save_data;
	$h->lock_file;
	#$h2->shared_ref->save_data;
	$h2->lock_file;
	
	
	trace "$0: lock_file called for ref: ".$ref->file, "\n";
	exit;
}
else
{
	sleep 0.5;
	kill 15, $pid;
	is($ref->unlock_if_stale(), 1, "Unlock if stale");
	
	my @files = HashNet::MP::LocalDB::cleanup_stale_locks();
	is(scalar(@files), 2, "cleanup_stale_locks()");
}

#sleep 60;


done_testing();



kill 15, $pid;
unlink($ref->file);
HashNet::MP::LocalDB->dump_db();

#HashNet::MP::LocalDB->dump_db($db_server_file);
#debug "$0: Done in $$, killed child $pid\n";


END{ 
}