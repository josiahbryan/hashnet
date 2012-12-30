#!/usr/bin/perl -w

use lib 'lib';

use strict;
use common::sense;
use HashNet::MP::SocketWorker;
use HashNet::MP::LocalDB;
use HashNet::MP::ClientHandle;
use HashNet::Util::Logging;

use IO::Socket;

my @hosts = @ARGV;

@hosts = ('localhost:8031') if !@hosts;

my $node_info;
## NOTE We call gen_node_info BEFORE setting DBFILE so that it uses system-wide db to cache UUID/$0 association
#$node_info = HashNet::MP::SocketWorker->gen_node_info;
$node_info = {
	uuid => 'b18934ff-ec2d-446c-84dd-ae96ab89d8ef',
	name => $0,
	type => 'client',
};

#$HashNet::MP::LocalDB::DBFILE = "$0.$$.db";
$HashNet::MP::LocalDB::DBFILE = "testdb";

my $ch;

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

#$ch->send("Test of ClientHandle");

#$ch->send("Bouncy Bouncy", to => $ch->uuid);

my $max_msgs = 1;
my $msg_size = 0; #1024 * 1024;

my $count = 0;
for my $x (1..$max_msgs)
{
	#if(!$ch->send("Hello # $x to PID $$", to => $ch->uuid, flush => 0))
	#my $msg = "Hello # $x to PID $$";
	my $msg = "Msg $x ".('#' x $msg_size);
	$count += length($msg);
	if(!$ch->send($msg, bcast => 1, flush => 0))
	{
		die "Unable to send message";
	}
}

#sleep 2;

#	my $worker = $ch->sw;
	
#	$worker->wait_for_start;

#	my $env = $worker->create_envelope("Hello, World", to => '58b4bd86-463a-4383-899c-c7163f2609b7'); #3c8d9969-4b58-4814-960e-1189d4dc76f9');
# 
# 	$worker->outgoing_queue->add_row($env);
# 
# 	$worker->wait_for_send;

#	$worker->stop;

$ch->wait_for_send;

#sleep 30;

$ch->wait_for_receive($max_msgs, 300); # 300 sec

sleep 1;
my @msgs = $ch->messages(0); # blocks [default 4 sec] until messages arrive, pass a false argument to not block

use Data::Dumper;
#print STDERR "Received: ".Dumper(\@msgs) if @msgs;
if(@msgs)
{
	#info "$0: Received msg '$_->{data}'\n" foreach @msgs;
	info "$0: Received ".scalar(@msgs)." messages\n";
}
else
{
	debug "$0: Did not receive any messages\n";
}

info "$0: Sent ".sprintf('%.02f', $count/1024)." KB\n";

info "$0: Disconnect from $ENV{REMOTE_ADDR}\n";


HashNet::MP::LocalDB->dump_db($HashNet::MP::LocalDB::DBFILE);
