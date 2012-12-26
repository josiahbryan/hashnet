#!/usr/bin/perl

use Test::More;

use common::sense;
use lib '../lib';
use lib 'lib';

use Time::HiRes qw/time sleep/;
use HashNet::MP::SharedRef;

my $datafile = "$0.dat";
my $time = time();

# Mute logging output
#$HashNet::Util::Logging::LEVEL = 0;

my $ref_tied    = HashNet::MP::SharedRef->new($datafile, 1);
#die "Test done";
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
		$ref->{time} = $time;
		$ref->save_data if !$tied;
		exit;
	}
	else
	{
		sleep 0.25;
		$ref->load_changes if !$tied;
		is($ref->{time}, $time, $type.' load from other fork');
	}

	kill 15, $pid;
	unlink($datafile);
	
}

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

