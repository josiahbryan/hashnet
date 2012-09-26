#!/usr/bin/perl

use strict;

use HashNet::StorageEngine;

use Time::HiRes qw/sleep time/;

my $idx = 4;
my $con = HashNet::StorageEngine->new(
	peers_list => ["http://127.0.0.1:805${idx}/db"],
	db_root	   => "/tmp/test/${idx}/db",
);

use Time::HiRes qw/time sleep/;

while($count ++ < 1000)
{
	#my $cur_val = int(rand() * 1000);
	my $cur_val = $count;
	
	$con->put('/test', $cur_val);
	sleep .1;
}
