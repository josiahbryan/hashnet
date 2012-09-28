#!/usr/bin/perl
use strict;

use TAP::Harness;
my $harness = TAP::Harness->new( { verbosity => 0 } );
my @tests = @ARGV ? @ARGV : <tests/*.t>;
$harness->runtests(@tests);
