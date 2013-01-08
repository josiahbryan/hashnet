#!/usr/bin/perl

use strict;

use Test::More;

use common::sense;
use lib '../lib';
use lib 'lib';

use HashNet::MP::SharedRef;
use HashNet::Util::Logging;
use Time::HiRes qw/sleep/;

# Necessary for the stale lock to be detected
$SIG{CHLD} = 'IGNORE';

# Mute logging output
$HashNet::Util::Logging::LEVEL = 0;
#$HashNet::Util::Logging::ANSI_ENABLED = 1 if $HashNet::Util::Logging::LEVEL;

my $ref = HashNet::MP::SharedRef->new();

my $pid = fork;
if(!$pid)
{
	$ref->lock_file();
	
	trace "$0: lock_file called for ref: ".$ref->file, "\n";
	exit;
}
else
{
	sleep 0.5;
	kill 15, $pid;

	is(HashNet::MP::SharedRef->is_lock_stale(),   -1, "No file arg to is_lock_stale()");
	is($ref->is_lock_stale(),   1, "Lock stale");

	is(HashNet::MP::SharedRef->unlock_if_stale(), -1, "No file arg to unlock_if_stale()");
	is($ref->unlock_if_stale(), 1, "Unlock if stale");

	my $ref2 = HashNet::MP::SharedRef->new();
	$ref2->lock_file;

	is($ref2->is_lock_stale(), 0, "Lock not stale");
	
	$ref2->unlock_file;
	unlink($ref2->file);
	
}

done_testing();

kill 15, $pid;
unlink($ref->file);

END{
}