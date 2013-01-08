#!/usr/bin/perl -w

use lib 'lib';

use strict;
use common::sense;
use HashNet::MP::ClientHandle;
use HashNet::Util::Logging;
use Time::HiRes qw/time/;
use Getopt::Std;

# Mute logging output
$HashNet::Util::Logging::LEVEL = 0;
$HashNet::Util::Logging::ANSI_ENABLED = 1 if $HashNet::Util::Logging::LEVEL;

my %opts;
getopts('?prsh:t:u:', \%opts);


if($opts{'?'}) # || !(scalar keys %opts))
{
	print qq{Usage: $0 [-?] [-h host(s)] [-t time] ([uuid] or [-u uuid])

  Options:
    -?       - This message
    -h       - One or more HashNet hubs, CSV
    -t	     - Seconds to wait for a broadcast ping (no UUID)
    -s	     - Print simple route (on by default)
    -r	     - Print complex route (off by default, overrides -s)
    -p	     - Print UUIDs of all hosts below names (does nothing if no -r)
    -u UUID  [or]
    UUID     - Optional UUID of a host/client to ping
               If no UUID given, sends a broadcast ping

};
	exit 0;
}

my $ping_uuid     = $opts{u} || shift @ARGV || undef;
my $ping_max_time = $opts{t} || 7;
my $complex_route = $opts{r} || 0;
my $simple_route  = $opts{s} || 1;
my $print_uuids   = $opts{p} || 0;

my @hosts = split /,/, $opts{h};

@hosts = ('localhost:8031') if !@hosts;

my $node_info;
## NOTE We call gen_node_info BEFORE setting DBFILE so that it uses system-wide db to cache UUID/$0 association
#$node_info = HashNet::MP::SocketWorker->gen_node_info;
$node_info = {
	uuid => 'dd697cb1-5daf-4c14-8600-8a2951534af1',
	name => $0,
	type => 'client',
};

#$HashNet::MP::LocalDB::DBFILE = "$0.$$.db";
$HashNet::MP::LocalDB::DBFILE = ".db.pingclient";

my $ch;

# Connect to a host to send the ping thru
while(my $host = shift @hosts)
{
	$ch = HashNet::MP::ClientHandle->connect($host, $node_info);
	if($ch)
	{
		$ENV{REMOTE_ADDR} = $host;
		info "Connected to $ENV{REMOTE_ADDR}\n";
		last;
	}
}
if(!$ch)
{
	die "Couldn't connect to any hosts (@hosts)";
}

# Print welcome message
if(!$ping_uuid)
{
	print "Pinging HashNet network via $ENV{REMOTE_ADDR} (max $ping_max_time sec)\n";
}
else
{
	print "Pinging HashNet node '$ping_uuid' (timeout $ping_max_time sec)\n";
}

# This is simply a user niceity to let them know something is actually happening
$ch->sw->fork_receiver('MSG_PONG' => sub {
		print " * Received PONG from '$_[0]->{data}->{node_info}->{name}'...\n" unless $ping_uuid;
	}, uuid => $ch->sw->uuid, no_del => 1);
	
# Do the real work
my @results = $ch->send_ping($ping_uuid, $ping_max_time);

#print STDERR Dumper(\@results);

# Create a hash of node UUIDs to node_info hashes from @results
my %nodes = map { $_->{node_info}->{uuid} => $_->{node_info} } @results;

# Add our own node_info to hash
$nodes{$node_info->{uuid}} = $node_info;

if($ping_uuid)
{
	# Even if we're pinging just a single UUID, all the hosts
	# along the route will have an entry in @results -
	# which is great for our %nodes hash for node_info, but 
	# we dont want to print them all out, so grep out everything
	# but the uuid we pinged
	@results = grep { $_->{msg}->{from} eq $ping_uuid } @results;
	if(!@results)
	{
		print "Could not ping '$ping_uuid'\n";
		exit -1; 
	}
}
else
{
	print "\n";
	print "Received ".scalar(@results)." results:\n".
	"-----------------------------------------------\n\n";
}

foreach my $res (@results)
{
	my $delta = $res->{time};
	my $start = $res->{start_t};
	my $msg   = $res->{msg};
	my @hist  = @{ $msg->{data}->{msg_hist} || [] };

	# Old/stale PONG message that was queued somewhere else and just now reached us on this run
	#next if $delta < 0;

	#print "$res->{node_info}->{name} - ".sprintf('%.03f', $delta)." sec\n";
	print sprintf('%.03f', $delta)." sec - $res->{node_info}->{name}\n";
	
	next if !$complex_route && !$simple_route;

	print "\t $0 -> " if $simple_route;

	my %ident;
	my $ident = 0;

	$hist[$#hist]->{last_item} = 1 if @hist;
	
	my $last_time = $start;
	foreach my $item (@hist)
	{
		my $time  = $item->{time};
		my $uuid1 = $item->{from};
		my $uuid2 = $item->{to};
		my $delta = $time - $last_time;
		my $info  = $nodes{$uuid2};

		
		if($complex_route)
		{
			my $ident = $ident{$uuid1} || ++ $ident;
			$ident{$uuid1} = $ident if !$ident{$uuid1};
			my $prefix = "\t" x $ident;
		
			print "$prefix -> " . ($nodes{$uuid1} ? $nodes{$uuid1}->{name} : $uuid1) . " -> " . ($info ? $info->{name} : $uuid2)." (".sprintf('%.03f', $delta)."s)\n";
			print "$prefix -> ( " . $uuid1 . " -> " . $uuid2 ." )\n" if $print_uuids;
		}
		else
		{
			print $info ? $info->{name} : $uuid2;
			print ' (', sprintf('%.03f', $delta), 's)';
			print " -> " unless $item->{last_item};
		}
		
		$last_time = $time;
	}
	print "\n";
	
}
print "\n";

HashNet::MP::LocalDB->dump_db($HashNet::MP::LocalDB::DBFILE);

