#!/usr/bin/perl

use strict;

#require 'StorageEngine.pm';
use HashNet::StorageEngine;
use Data::Dumper;

#use File::Path qw/rmtree/;

#my $tmp_dbroot = '/tmp/hashnet/db';
#rmtree($tmp_dbroot);

# my $key = HashNet::StorageEngine::sanatize_key('foobar;');
# 
# if(!$key && $@)
# {
# 	warn "[ERROR] StorageEngine: get(): Invalid key: $@";
# 	#return undef;
# }
# 
# die "Test done";


my $con = HashNet::StorageEngine->new(); #db_root => $tmp_dbroot);

#$con->put('/global/date', `date`);

#my $val = $con->get('/global/date');
#print "Retrieved: ", $val, "\n";

my $res = $con->list('/');

print Dumper $res;
