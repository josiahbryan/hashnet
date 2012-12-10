#!/usr/bin/perl
use strict;
use lib 'lib';
use HashNet::MP::LocalDB;
use Data::Dumper;
print Dumper( HashNet::MP::LocalDB->handle );
