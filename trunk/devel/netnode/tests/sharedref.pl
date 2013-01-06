#!/usr/bin/perl

use Test::More;

use common::sense;
use lib '../lib';
use lib 'lib';

use Time::HiRes qw/time sleep alarm/;
use HashNet::MP::SharedRef;
use HashNet::Util::Logging;

my $datafile = "$0.dat";
my $time = time();

# Mute logging output
$HashNet::Util::Logging::LEVEL = 0;
#$HashNet::Util::Logging::ANSI_ENABLED = 1;

my $ref_tied    = HashNet::MP::SharedRef->new($datafile, 1);
test_ref($ref_tied, 'Tied');

my $ref_normal  = HashNet::MP::SharedRef->new($datafile, 0);
test_ref($ref_normal, 'Normal');

sub test_ref
{
	my ($ref, $type) = @_;
	my  $tied = $type eq 'Tied';
	is(($tied ? (tied(%{$ref})) : $ref)->file,  $datafile, $type.' datafile');

	$ref->{time} = $time;
	is($ref->{time}, $time, $type.' set/get');

	$time = time() + 1;
	
	my $pid = fork;
	if(!$pid)
	{
		trace "$0: Write fork\n";
		$ref->{time} = $time;
		$ref->save_data if !$tied;

		if(!$tied)
		{
			$ref->lock_file;
			sleep 1;
			$ref->unlock_file;
		}
		exit;
	}
	else
	{
		sleep 0.25;
		trace "$0: Read fork\n";
		$ref->load_changes if !$tied;
		is($ref->{time}, $time, $type.' load from other fork');
	}

	#kill 15, $pid;
	unlink($datafile);
	
}

#die "Test done";

ok($ref_normal->lock_file, "Lock file");
is($ref_normal->lock_file, 2, "Lock file again");
is($ref_normal->unlock_file, 2, "Unlock file");
is($ref_normal->unlock_file, 1, "Unlock file (really)");
is($ref_normal->lock_file, 1, "Lock file after unlock");
ok($ref_normal->unlock_file, "Unlock file again");


done_testing();

# die "Test done";
# 
# 
# 
# 
# # Create one fork to create data
# if(!fork)
# {
# 	$ref_normal->set_data({ time => $time });
# 	$ref_normal->{time2} = $time;
# 	$ref_normal->save_data;
# 	#$ref_normal->{time} = $time;
# 
# 	exit;
# }
# else
# {
# 	sleep 0.1;
# 	
# 	is($ref_normal->data->{time}, $time, "Data auto-load from other fork");
# 	is($ref_normal->{time2}, $time, "Direct set/fetch works");
# 	#is($ref_normal->{time}, $time, "Direct set/fetch works");
# }
# 
# #use Data::Dumper;
# #print Dumper $ref_normal, $ref_normal->_d;
# 
# unlink($datafile);
# done_testing();

