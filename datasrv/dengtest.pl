#!/usr/bin/perl

use strict;

#require 'StorageEngine.pm';
use HashNet::StorageEngine;

my $con = HashNet::StorageEngine->new;

my $date = `date`;
$date =~ s/[\r\n]//g;

$con->put('/global/date', $date);

my $val = $con->get('/global/date');
print "Retrieved: ", $val, "\n";
# 
# print "Sleeping\n";
# while(1){
# 	sleep 1;
# }
