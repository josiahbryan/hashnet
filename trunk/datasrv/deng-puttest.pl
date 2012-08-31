#!/usr/bin/perl

use strict;

#require 'StorageEngine.pm';
use HashNet::StorageEngine;

use Time::HiRes qw/sleep time/;

use Getopt::Std;
my %opts;
getopts('c:d:v:', \%opts);

my $con = HashNet::StorageEngine->new(
	config	=> $opts{c},
	db_root	=> $opts{d}
);

#my $date = `date`;
#$date =~ s/[\r\n]//g;

#my $val = @ARGV ? shift : 1;
my $val = $opts{v} || 1;

my $count = 10000;
my $start = time;
for(0..$count-1)
{
	print "-> $_\n";
	$con->put('/global/test', $val);
};
my $end = time;
my $delta = $end-$start;

print "Put '$val' at ", `date`;

my $avg = $delta / $count;
print "Time: $delta sec, Avg time: $avg sec\n";

#$con->put('/global/test', 0); # Reset value

#my $val = $con->get('/global/date');
#print "Retrieved: ", $val, "\n";
# 
# print "Sleeping\n";
# while(1){
# 	sleep 1;
# }
