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


my @results = $ch->send_ping();

my %nodes = map { $_->{node_info}->{uuid} => $_->{node_info} } @results;

print "\n\n";
foreach my $res (@results)
{
	my $delta = $res->{time};
	my $start = $res->{start_t};
	my $msg   = $res->{msg};
	my @hist  = @{ $msg->{data}->{msg_hist} || [] };

	#print "$res->{node_info}->{name} - ".sprintf('%.03f', $delta)." sec\n";
	print sprintf('%.03f', $delta)." sec - $res->{node_info}->{name}\n";

	print "\t $0 -> ";

	$hist[$#hist]->{last} = 1 if @hist;
	my $last_from = undef;
	foreach my $item (@hist)
	{
		#next if $item->{from} eq $last_from;
		
		my $time  = $item->{time};
		my $uuid  = $item->{to};
		my $delta = $time - $start;
		my $info  = $nodes{$uuid};
		next if !$info;
		
		print "$info->{name} (".sprintf('%.03f', $delta)."s)";
		print " -> " unless $item->{last};
		#$last_from = $item->{from};
	}

	print "\n";
	
}


HashNet::MP::LocalDB->dump_db($HashNet::MP::LocalDB::DBFILE);