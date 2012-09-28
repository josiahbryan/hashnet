#!/usr/bin/perl
use strict;

package MyHarness;
{
	use base 'TAP::Harness';
	sub make_parser
	{
		my ( $self, $job ) = @_;
		my ( $parser, $session ) = $self->SUPER::make_parser($job);
		
		# Necessary because some tests can't get the exit status to zero due to forking and killing forks on exit
		$parser->ignore_exit(1);
		
		return ( $parser, $session );
	}
};

package main;
{
	my $harness = MyHarness->new( { verbosity => 0 } );
	my @tests = @ARGV ? @ARGV : <tests/*.t>;
	$harness->runtests(@tests);
};