#!/usr/bin/perl

use strict;

use HashNet::StorageEngine;
use LWP::Simple qw/get/;

use Time::HiRes qw/sleep time/;

my $idx = 1;
my $con = HashNet::StorageEngine->new(
	peers_list => ["http://127.0.0.1:805${idx}/db"],
	db_root	   => "/tmp/test/${idx}/db",
);

use Time::HiRes qw/time sleep/;
# 
# my $count = 0;
# while($count ++ < 1)
# {
# 	#my $cur_val = int(rand() * 1000);
# 	my $cur_val = { count => $count, time => time() };
# 	
# 	$con->put('/test', $cur_val);
# 	sleep .1;
# }


#my $file = "./www/images/hashnet-logo.png";
#my $file = "/home/josiah/Pictures/2012-09-04\\ Historical\\ UC/dsc_6764.jpg";
my $file = "test-img.jpg";
my $data = `cat $file`;

#my $data = get("http://10.1.3.3/jpg/image.jpg");

my $len = length($data);
print "len of data: $len\n";

$con->put('/test', $data);