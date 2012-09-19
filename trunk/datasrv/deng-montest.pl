#!/usr/bin/perl

use strict;

#require 'StorageEngine.pm';
use HashNet::StorageEngine;

use File::Path qw/rmtree/;

#my $tmp_dbroot = '/tmp/hashnet/db';
#rmtree($tmp_dbroot);

my $con = HashNet::StorageEngine->new(config => 'montest.cfg');#db_root => $tmp_dbroot);

#$con->put('/date', `date`);

my $start_date = $con->get('/test');

my $done = 0;
while(!$done)
{
	print "Waiting, ", `date`;
	my $val = $con->get('/test');
	if($val != $start_date)
	{
		print "Got val $val (old $start_date) at ", `date`;
		$done = 1;	
	}
	sleep 1;
}
#print "Retrieved: ", $val, "\n";
# 
# print "Sleeping\n";
# while(1){
# 	sleep 1;
# }
