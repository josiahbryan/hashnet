#!/usr/bin/perl
use strict;
use Test::Harness;
my @test_files = `ls tests/*.pl`;
s/[\r\n]//g foreach @test_files;
runtests(@test_files);

# TODO add test for multiple hubs, client receipt travel across hubs and erase appros messages