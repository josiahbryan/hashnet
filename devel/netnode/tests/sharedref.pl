#!/usr/bin/perl

use Test::More;

use common::sense;
use lib '../lib';
use lib 'lib';

use Time::HiRes qw/time sleep/;
use HashNet::MP::SharedRef;

my $datafile = "$0.dat";


my $ref = HashNet::MP::SharedRef->new($datafile);

my $time = time();

# Create one fork to create data
if(!fork)
{
	$ref->set_data({ time => $time });

	exit;
}
else
{
	sleep 0.1;
	
	is($ref->data->{time}, $time, "Data auto-load from other fork");
}

unlink($datafile);
done_testing();

