#!/usr/bin/perl

# MUST be use'd as the very first thing in the main program,
# as it clones/forks the program before it returns.
use AnyEvent::Watchdog;
use AnyEvent::Watchdog::Util;

use strict;
use warnings;


my $message = "Hello, World!";

#while(1)
my $count = 0;
while(++ $count < 3)
{
	print time()." [$count]: $message\n";
	sleep(1);
}


# check if it is running
if(AnyEvent::Watchdog::Util::enabled)
{
	# attempt restart
	AnyEvent::Watchdog::Util::restart;
}
else
{
	die "not running under watchdog!";
}
