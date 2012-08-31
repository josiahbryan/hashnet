#!/usr/bin/perl
use strict;
use JSON qw/to_json/;
# use HashNet::StorageEngine;
# 
# my $con = HashNet::StorageEngine->new(
# 	peers => ['http://mypleasanthillchurch.org:8031/db/'],
# );


use LWP::Simple qw/get/;
use Data::Dumper;
use Digest::MD5 qw/md5_hex/;
use Storable qw/store retrieve/;

my $search_url_base = 'http://mypleasanthillchurch.org:8031/db/search?path=';

sub query($)
{
	my $query = shift;
	my $cache_dir = '/tmp/mapgen-querycache/';
	system("mkdir -p $cache_dir") if !-d $cache_dir;
	my $cache_file = $cache_dir.md5_hex($query);
	my $content;
	$content = retrieve($cache_file)->{html} if -f $cache_file;
	if(!$content)
	{
		my $url = $search_url_base.$query;
		print "[INFO] Downloading $url to $cache_file\n";
		$content = get($url);
		store({html=>$content}, $cache_file);
	}
	
	my %results = $content =~ /<tr><td>(.*?)<\/td><td>(.*)<\/td><\/tr>/g;
	return %results;
}

# Get list of hosts
my %res = query('/global/nodes');

#die Dumper \%res;
my $tree = {};

# Build into a hash-of-hashes
foreach my $key (keys %res)
{
	#print "key: $key, val: '$res{$key}'\n";
	my @parts = split /\//, $key;
	my $current_ref = $tree;
	shift @parts;
	#print Dumper \@parts;
	while(my $item = shift @parts)
	{
		if(@parts)
		{
			$current_ref->{$item} ||= {};
			$current_ref = $current_ref->{$item};
		}
		else
		{
			$current_ref->{$item} = $res{$key};
		}
	}
	
	#die Dumper $tree;
}

#print Dumper $tree;

my $count = 0;

my @json_list;

sub normalize
{
	my ($x,$y) = @_;
	return ($x cmp $y) < 0 ? "$x$y" : "$y$x";
}

my %links_added;

my $nodes = $tree->{global}->{nodes};
foreach my $node_uuid (keys %{$nodes || {}})
{
	my $node =  $nodes->{$node_uuid};
	my $geo = $node->{geo_info};
	if(!$geo)
	{
		warn "No geo info for $node_uuid";
		next;
	}
	my ($lat, $lng) = $geo =~ /, (-?\d+\.\d+), (-?\d+\.\d+)/;
	
	print STDERR "$node->{name} ($lat, $lng)\n";
	
	my $node_json = {
		name => $node->{name},
		geo  => $geo,
		lat  => $lat,
		lng  => $lng,
	};
	
	my @links;
	my @peers = keys %{$node->{peers} || {}};
	foreach my $peer_uuid (@peers)
	{
		my $peer = $nodes->{$peer_uuid};
		my $geo = $peer->{geo_info};
		if(!$geo)
		{
			warn "No geo info for peer $peer_uuid";
			next;
		}
		my ($lat, $lng) = $geo =~ /, (-?\d+\.\d+), (-?\d+\.\d+)/;
		
		print STDERR "\t -> $peer->{name} ($lat, $lng)\n";
		
		my $link_key = normalize($node_uuid, $peer_uuid);
		if(!$links_added{$link_key})
		{
			push @links, { lat => $lat, lng => $lng };
			$links_added{$link_key} = 1;
		}
		
		$node_json->{links} = \@links;
	}

	push @json_list, $node_json;
	$count ++;
}

print STDERR Dumper \@json_list;
print "map_list=", to_json(\@json_list), "\n";
