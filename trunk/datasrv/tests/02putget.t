#!/usr/bin/perl
use strict;
use lib '..';

use Test::More;

# Setup
# Create peer server or use configured server
# Setup engine and peer

use HashNet::StorageEngine;
use LWP::Simple qw/get/;
use Time::HiRes qw/sleep time/;
use UUID::Generator::PurePerl;
use URI::Escape;

my $ug = UUID::Generator::PurePerl->new();

my $idx = 1;
my $con = HashNet::StorageEngine->new(
	peers_list => ["http://127.0.0.1:805${idx}/db"],
	db_root	   => "/tmp/test/${idx}/db",
);

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
		
		my $num_tests = 2;
		skip "because $peer->{url} is offline", $num_tests unless ! $peer->host_down;
		
		my $req_uuid = $ug->generate_v1->as_string();
		
		is($peer->pull($key, $req_uuid), $data, "Pull $key from $peer->{url}");
		
		ok(!$peer->pull($key, $req_uuid), "Duplicate pull deny");
		
		# Test /db/put URL
		{
			my $url = $peer->{url} . '/put';
			
			$url .= '?key='.uri_escape($key);
			$url .= '&data='.uri_escape($data);
			
			like(get($url), qr/^OK/, "/db/put test");
		}
		
		# Test /db/put URL - alternate data key
		{
			my $url = $peer->{url} . '/put';
			
			$url .= '?key='.uri_escape($key);
			$url .= '&value='.uri_escape($data);
			
			like(get($url), qr/^OK/, "/db/put test alternate data key");
		}
		
		# Test /db/put URL via POST
		{
			my $url = $peer->{url} . '/put';
			
			$url .= '?key='.uri_escape($key);
			
			my $ua = LWP::UserAgent->new;
			$ua->timeout(10);
			$ua->env_proxy;
			
			my $response = $ua->post($url, Content => $data );

			ok($response->is_success, "HTTP POST ok");
			
			diag($response->status_line) if !$response->is_success;
			
			like($response->decoded_content, qr/^OK/, "/db/put POST test");
		}
		
		# Setup binary data
		{
			#my $file = "./devel/viz/img/rectangle.png";
		
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
			is($con->put($key, $data), $key, "Put binary data");
			
			# Test pull binary data
			is($peer->pull($key), $data, "Pull binary data for $key from $peer->{url}");
		}
	};
	
}

#my 


# # Test binary
# my $file = "test-img.jpg";
# my $data = `cat $file`;
# 
# $con->put('/test', '1');


done_testing();