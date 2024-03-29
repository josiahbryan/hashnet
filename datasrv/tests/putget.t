#!/usr/bin/perl
use strict;
use lib '..';

use Test::More;

use HashNet::StorageEngine;
use LWP::Simple qw/get/;
use Time::HiRes qw/sleep time/;
use UUID::Generator::PurePerl;
use URI::Escape;
use File::Path qw/mkpath/;

# Make logging quiet so we can read test output more easily
use HashNet::Util::Logging;
$HashNet::Util::Logging::LEVEL = 0;


my $ug = UUID::Generator::PurePerl->new();

my $idx = 1;
my $db_root = "/tmp/test/${idx}/db";

if(!-d $db_root)
{
	mkpath($db_root);
}

my $con = HashNet::StorageEngine->new(
	peers_list => ["http://127.0.0.1:805${idx}/db"],
	db_root	   => $db_root,
);

my $server_pid = -1;
if($con->peers->[0]->host_down)
{
	#die "Peer 0 down";
	#perl ./dengpeersrv.pl -p 8051 -c /tmp/test/1/peers.cfg -n /tmp/test/1/node.cfg -d /tmp/test/1/db
	if(my $pid = fork)
	{
		$server_pid = $pid;
	}
	else
	{
		logmsg 'INFO', "Creating PeerServer's StorageEngine...\n";
		my $engine = HashNet::StorageEngine->new(
			peer_list => [],
			db_root	=> $db_root,
		);

		# if(-f $bin_file)
		# {
		# 	info "$app_name: Using bin_file to '$bin_file'\n";
		# }

		logmsg 'INFO', "Creating PeerServer...\n";
		my $srv = HashNet::StorageEngine::PeerServer->new(
			engine   => $engine,
			port     => "805${idx}",
		);

		$srv->run;

		exit;
	};

	logmsg 'INFO', "Waiting 1.5 sec for peer server to startup...\n";
	sleep(1.5);
	
	logmsg 'INFO', "Assuming server running, continuing with test\n";
	my $peer = $con->peers->[0];
	$peer->update_begin;
	$peer->{host_down} = 0;
	$peer->update_end;
}

my $key = '/test';
# Ensure non-zero because "Duplicate pull deny" uses "!" to test
my $data = int(rand() * 1000) + 1;

# Test basic 'put'
is($con->put($key, $data), $key, "Put $key => $data");

# Test basic 'get'
is($con->get($key), $data, "Get $key");

# Test pull from peer - note, will fail if peer isn't running
{
	my @peers = @{ $con->peers || [] };
	my $peer = shift @peers;
	ok(defined $peer, "Valid peer");
	
	SKIP: {
		#ok(!$peer->host_down, "$peer->{url} online");
		
		my $num_tests = 6;
		skip "because $peer->{url} is offline", $num_tests unless ! $peer->host_down;
		
		my $req_uuid = $ug->generate_v1->as_string();
		
		# Test simple pull of the value we put earlier
		{
			is($peer->pull($key, $req_uuid), $data, "Pull $key from $peer->{url}");
		}
		
		# Make sure the server denies pulls with the same uuid
		{
			ok(!$peer->pull($key, $req_uuid), "Duplicate pull deny");
		}
		
		# Test /db/put URL
		{
			my $url = $peer->{url} . '/put';
			
			$url .= '?key=' .uri_escape($key);
			$url .= '&data='.uri_escape($data);
			
			like(get($url), qr/^OK/, "/db/put $key");
		}
		
		# Test /db/put URL - alternate data key
		{
			my $url = $peer->{url} . '/put';
			
			$url .= '?key='  .uri_escape($key);
			$url .= '&value='.uri_escape($data);
			
			like(get($url), qr/^OK/, "/db/put $key with alternate data key");
		}
		
		# Test /db/put URL via POST
		{
			my $url = $peer->{url} . '/put';
			
			$url .= '?key='.uri_escape($key);
			
			my $ua = LWP::UserAgent->new;
			$ua->timeout(10);
			$ua->env_proxy;
			
			my $response = $ua->post($url, Content => $data );

			ok($response->is_success, "/db/put POST HTTP response is_success");
			
			diag($response->status_line) if !$response->is_success;
			
			like($response->decoded_content, qr/^OK/, "/db/put POST rxd OK");
		}
		
		# Setup binary data
		my $img = "www/images/hashnet-logo.png";
		#my $img = "test-img.jpg";
		my $file = "../" . $img;
		if(!-f $file)
		{
			$file = $img;
		}
		
		my $data = `cat $file`;
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
			is($con->put($key, $data), $key, "Put binary data");
			
			# This makes use of the server's tr_push and Peer's push() method,
			# below, we test to make sure the server received the binary data
			# properly by making sure we can retrieve it
		}
		
		# Test pull binary data
		{
			is($peer->pull($key), $data, "Pull binary data for $key from $peer->{url}");
		}
		
	};
	
}

done_testing();

if($server_pid > 0)
{
	logmsg 'INFO', "Killing $server_pid"; 
	kill 15, $server_pid;
}
