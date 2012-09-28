#!/usr/bin/perl
use strict;
use lib '..';

use Test::More;

use HashNet::StorageEngine;
use LWP::Simple qw/get/;
use Time::HiRes qw/sleep time/;
use UUID::Generator::PurePerl;
use URI::Escape;
use File::Path qw/mkpath rmtree/;

# Make logging quiet so we can read test output more easily
use HashNet::Util::Logging;
$HashNet::Util::Logging::LEVEL = 99;


my $ug = UUID::Generator::PurePerl->new();

my %cons;

my $PEER_PORT_PREFIX = 6550;

for my $idx (1..2)
{
	my $test_root = "/tmp/test/$$-${idx}";
	
	if(!-d $test_root)
	{
		mkpath($test_root);
	}
	
	my $peer_port = "${PEER_PORT_PREFIX}${idx}";
		
	my $con = HashNet::StorageEngine->new(
		peers_list => ["http://127.0.0.1:${peer_port}/db"],
		db_root	   => $test_root .'/db',
	);
	
	$cons{$idx} = $con;
	$con->{server_pid} = -1;
	$con->{test_root} = $test_root;
	
	if($con->peers->[0]->host_down)
	{
		if(my $pid = fork)
		{
			$con->{server_pid} = $pid;
		}
		else
		{
			my $peer_url = "http://127.0.0.1:$PEER_PORT_PREFIX". ($idx == 1 ? 2 : 1) . "/db";
			print STDERR "Peer $idx: Creating PeerServer's StorageEngine for other peer '$peer_url'...\n";
			my $engine = HashNet::StorageEngine->new(
				# Peer idx 1 with idx 2, and vis a versa
				peer_list => [$peer_url],
				db_root   => $test_root . '/db',
			);
			
			# if(-f $bin_file)
			# {
			# 	info "$app_name: Using bin_file to '$bin_file'\n";
			# }
	
			print STDERR "Peer $idx: Creating PeerServer...\n";
			my $srv = HashNet::StorageEngine::PeerServer->new(
				engine   => $engine,
				port     => $peer_port,
				# Set a node.cfg file so it can store a unique uuid for this server per $idx 
				config   => $test_root.'/node.cfg',
			);
	
			print STDERR "Peer $idx: Starting server...\n";
			$srv->run;
	
			exit;
		};
	
		print STDERR "Peer $idx: Waiting a few sec for peer server $peer_port to startup...\n";
		sleep(1.5);
		
		diag("Peer $idx: Assuming server $peer_port running, continuing with test\n");
		
		my $peer = $con->peers->[0];
		$peer->update_begin;
		$peer->{host_down} = 0;
		$peer->update_end;
	}
}

my $key = '/test';
# Ensure non-zero because "Duplicate pull deny" uses "!" to test
my $data = int(rand() * 1000) + 1;

if($cons{1}->in_batch_update)
{
	diag("Turning off batch update on con 1");
	$cons{1}->end_batch_update();
}

# Test basic 'put'
my $put_result = $cons{1}->put($key, $data);
is($put_result, $key, "Put $key => $data");

goto DONE_TESTING if $put_result ne $key;

# Test basic 'get'
is($cons{1}->get($key), $data, "Get $key from peer 1 (local engine)");

# Give it at most 5 seconds to propogate the data
my $time_start = time;
my $peer2_data;
while(($peer2_data ne $data) && 
      (time - $time_start) < 5.0)
{
	sleep .25;
	$peer2_data = $cons{2}->get($key);
}

# Test 2nd 'get'
is($peer2_data, $data, "Get $key from peer 2");


# Setup binary data
my $img = "www/images/hashnet-logo.png";
#my $img = "test-img.jpg";
my $file = "../" . $img;
if(!-f $file)
{
	$file = $img;
}

$data = `cat $file`;
my $len = length($data);

#print "len of data: $len\n";
#die "Cannot read file: $file" if $len <= 0;
if($len <= 0)
{
	# Fill in a simple non-printable (well, outside :print: range) character
	$data = chr(244);
}

# Test binary data put/get
{
	is($cons{1}->put($key, $data), $key, "Put binary data in $key");
	
	# This makes use of the server's tr_push and Peer's push() method,
	# below, we test to make sure the server received the binary data
	# properly by making sure we can retrieve it
}

# Give it at most 5 seconds to propogate the data
my $time_start = time;
$peer2_data = undef;
while(($peer2_data ne $data) && 
      (time - $time_start) < 5.0)
{
	sleep .5;
	$peer2_data = $cons{2}->get($key);
	diag("Got $key => '$peer2_data'");
}

# Test pull binary data
{
	#is($peer->pull($key), $data, "Pull binary data for $key from $peer->{url}");
	ok($peer2_data eq $data, "Get binary data from $key in peer 2"); #$peer->{url}");
}


DONE_TESTING:
done_testing();

foreach my $con (values %cons)
{
	kill 15, $con->{server_pid}
		if $con->{server_pid} > 0;
	
	rmtree($con->{test_root});
}


