#!/usr/bin/perl

use strict;

use HashNet::StorageEngine;

use Time::HiRes qw/sleep time/;

my %cons;
my $num_cons = 4;
for my $idx (1..$num_cons)
{
	$cons{$idx} = HashNet::StorageEngine->new(
		peers_list => ["http://127.0.0.1:805${idx}/db"],
		db_root	   => "/tmp/test/${idx}/db",
	);
}


my $injector = 4;

use Time::HiRes qw/time sleep/;
my $count = 0;
my $time_sum = 0;
while($count ++ < 100)
{
	#my $cur_val = int(rand() * 1000);
	my $cur_val = $count;
	
	$cons{$injector}->put('/test', $cur_val);
	
	foreach my $con (values %cons)
	{
		$con->{_bad_count} = 0;
		$con->{_good} = 0;
	}

	my $time_start = time;
	print "[$count] Injected new current val '$cur_val' at $time_start\n";
	
	my $good_count = 0;
	while($good_count < $num_cons)
	{
		for my $idx (1..$num_cons)
		{
			my $con = $cons{$idx};
			if(!$con->{_good})
			{
				#print "\t Checking $idx...\n";
				my $test = $con->get('/test');
				#print "\t     Done $idx.\n";
				if($test == $cur_val)
				{
					$con->{_good} = 1;
					$good_count ++;
					print "[$count] Con $idx is good\n";
				}
				else
				{
					$con->{_bad_count} ++;
				}
			}
		}
		#sleep .1;
	}
	
	my $time_end = time;
	my $time_diff = $time_end - $time_start;
	print "[$count] All good, it took $time_diff seconds for val '$cur_val'\n";
	$time_sum += $time_diff;
}

print "Test done, Avg time was ", ($time_sum/$count), " seconds\n";