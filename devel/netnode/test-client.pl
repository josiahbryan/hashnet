#!/usr/bin/perl -w

use lib 'lib';

use strict;
use common::sense;
use HashNet::MP::SocketWorker;
use HashNet::MP::LocalDB;
use HashNet::MP::ClientHandle;
use HashNet::Util::Logging;

use IO::Socket;

#$HashNet::Util::Logging::ANSI_ENABLED = 1;

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

my $max_msgs = 1024;
my $msg_size = 1024; # * 1024;

#$ch->outgoing_queue->pause_update_saves;

my $count = 0;
for my $x (1..$max_msgs)
{
	#if(!$ch->send("Hello # $x to PID $$", to => $ch->uuid, flush => 0))
	#my $msg = "Hello # $x to PID $$";
	my $msg = "Msg $x";
	my $att = '#' x $msg_size;
	$count += length($msg) + $msg_size;
	if(!$ch->send($msg, _att => $att, bcast => 1, flush => 1))
	{
		die "Unable to send message";
	}
}

#$ch->outgoing_queue->resume_update_saves;

#sleep 2;

#	my $worker = $ch->sw;
	
#	$worker->wait_for_start;

#	my $env = $worker->create_envelope("Hello, World", to => '58b4bd86-463a-4383-899c-c7163f2609b7'); #3c8d9969-4b58-4814-960e-1189d4dc76f9');
# 
# 	$worker->outgoing_queue->add_row($env);
# 
# 	$worker->wait_for_send;

#	$worker->stop;

trace "$0: Wait for send\n";
my $res = $ch->wait_for_send;
trace "$0: Wait res: $res\n";

#sleep 30;

trace "$0: Wait for receive\n";
$res = $ch->wait_for_receive($max_msgs, 300); # 300 sec
trace "$0: Wait res: $res\n";

sleep 1;
trace "$0: Pickup messages\n";
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

info "$0: Disconnect from $ENV{REMOTE_ADDR}\n\n\n";


HashNet::MP::LocalDB->dump_db($HashNet::MP::LocalDB::DBFILE);

