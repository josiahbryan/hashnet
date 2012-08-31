#!/usr/bin/perl

use strict;

#require 'StorageEngine.pm';
use HashNet::StorageEngine;

use File::Path qw/rmtree/;

my $tmp_dbroot = '/tmp/hashnet/db';
#rmtree($tmp_dbroot);

my $con = HashNet::StorageEngine->new(db_root => $tmp_dbroot);

#$con->put('/global/date', `date`);

my $val = $con->get('/global/date');
print "Retrieved: ", $val, "\n";
# 
# print "Sleeping\n";
# while(1){
# 	sleep 1;
# }
