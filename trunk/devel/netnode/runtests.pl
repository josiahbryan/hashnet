#!/usr/bin/perl
use strict;
use Test::Harness;
my @test_files = `ls tests/*.pl`;
s/[\r\n]//g foreach @test_files;
runtests(@test_files);
