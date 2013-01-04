#!/usr/bin/perl -w

use lib 'lib';

use strict;
use common::sense;
use HashNet::MP::SocketWorker;
use HashNet::MP::LocalDB;
use HashNet::MP::ClientHandle;
use HashNet::Util::Logging;
use Time::HiRes qw/time/;

use IO::Socket;

#$HashNet::Util::Logging::ANSI_ENABLED = 1;

# Mute logging output
$HashNet::Util::Logging::LEVEL = 0;

my @hosts = @ARGV;

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

my $t_start = time;

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


print "Pinging HashNet network via $ENV{REMOTE_ADDR} (takes approx 10 sec)\n";

my @results = $ch->send_ping(undef, 10.);

my %nodes = map { $_->{node_info}->{uuid} => $_->{node_info} } @results;

# Add our own node_info to hash
$nodes{$node_info->{uuid}} = $node_info;

print "\n\n";
foreach my $res (@results)
{
	my $delta = $res->{time};
	my $start = $res->{start_t};
	my $msg   = $res->{msg};
	my @hist  = @{ $msg->{data}->{msg_hist} || [] };

	# Old/stale PONG message that was queued somewhere else and just now reached us on this run
	next if $delta < 0;

	#print "$res->{node_info}->{name} - ".sprintf('%.03f', $delta)." sec\n";
	print sprintf('%.03f', $delta)." sec - $res->{node_info}->{name}\n";

	#print "\t $0 -> ";

	my %ident;
	my $ident = 0;

	$hist[$#hist]->{last} = 1 if @hist;
	my $last_to = undef;
	my $last_time = $start;
	foreach my $item (@hist)
	{
		#next if defined $last_to && !$item->{last} && $item->{from} ne $last_to;
		
		my $time  = $item->{time};
		my $uuid  = $item->{to};
		my $uuid2 = $item->{from};
		my $delta = $time - $last_time;
		my $info  = $nodes{$uuid};

		#next if !$info;
		my $key = $uuid2; #.$uuid;
		my $ident = $ident{$key} || ++ $ident;
		$ident{$key} = $ident;
		my $prefix = "\t" x $ident;
		
		#print "$prefix -> " . ($info ? $info->{name} : ($nodes{$uuid2} ? $nodes{$uuid2}->{name} : $uuid2) . " -> $uuid")." (".sprintf('%.03f', $delta)."s)\n";
		print "$prefix -> " . ($nodes{$uuid2} ? $nodes{$uuid2}->{name} : $uuid2) . " -> " . ($info ? $info->{name} : $uuid)." (".sprintf('%.03f', $delta)."s)\n";
		#print " -> " unless $item->{last};

		$last_to = $uuid;
		$last_time = $time;
	}

	print "\n";
	
}


HashNet::MP::LocalDB->dump_db($HashNet::MP::LocalDB::DBFILE);

