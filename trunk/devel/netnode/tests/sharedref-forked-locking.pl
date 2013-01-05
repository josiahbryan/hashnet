#!/usr/bin/perl

use strict;

use Test::More;

use common::sense;
use lib '../lib';
use lib 'lib';

use HashNet::MP::SharedRef;
use HashNet::Util::Logging;
use Time::HiRes qw/sleep/;

# Mute logging output
$HashNet::Util::Logging::LEVEL = 0;

my $ref = HashNet::MP::SharedRef->new();

my $pid = fork;
if($pid == 0)
{
	# in child
	trace "Child forked\n";
	if($ref->lock_file)
	{
		#ok(1, "Child locked file");
		$ref->load_changes;
		my $len = 1;
		trace "Child: File locked, sleeping $len sec\n";
		sleep $len;
		$ref->{test} = $$;
		trace "Child: Sleep done, set {test} to $$\n";
		$ref->save_data;
		$ref->unlock_file;
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
	if($ref->lock_file)
	{
		ok(1, "Parent locked file");
		trace "Parent: File locked, testing data\n";
		$ref->load_changes;
		trace "Parent: PID from file: $ref->{test}, real child: $pid\n";
		is($ref->{test}, $pid, "Load child PID from file");
		$ref->unlock_file;
	}
	else
	{
		trace "Parent: unable to lock file\n";
		ok(0, "Lock file in parent");
	}
}

trace "Test over, deleting file: ".$ref->file."\n";
unlink($ref->file);

done_testing();
