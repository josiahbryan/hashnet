#!/usr/bin/perl
use strict;
use warnings;

if(my $pid = fork)
{
	print "$$: Forked watcher $pid\n";
}
else
{
	my $parent = getppid();
	print "$$: In Watcher, parent: $parent\n";
	while(1)
	{
		my $count = `ps $parent | wc -l` + 0;
		if($count <= 1)
		{
			print "$$: Parent $parent died, restarting\n";
			
			system("perl $0 &");# if !fork;
			exit;
		}
	}
	#exit;
}

my $message = "Foobar framitz";

#while(1)
my $count = 0;
while(++ $count < 3)
{
	print time()." [$count]: $message\n";
	sleep(1);
}