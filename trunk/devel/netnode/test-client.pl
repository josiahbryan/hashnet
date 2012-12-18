#!/usr/bin/perl -w

use lib 'lib';

use strict;
use common::sense;
use HashNet::MP::SocketWorker;
use HashNet::MP::LocalDB;
use HashNet::MP::ClientHandle;
use HashNet::Util::Logging;

use IO::Socket;

my ($host, $port) = @ARGV;

$host = 'localhost' if !$host;
$port = 8031 if !$port;

$HashNet::MP::LocalDB::DBFILE = "$0.db";

if(1)
{
	my $ch = HashNet::MP::ClientHandle->new($host, $port);


	$ENV{REMOTE_ADDR} = $host;
	info "Connected to $ENV{REMOTE_ADDR}\n";

	#$ch->send("Test of ClientHandle");

	#$ch->send("Bouncy Bouncy", to => $ch->uuid);

	for my $x (1..4)
	{
		$ch->send("Slam # $x", to => $ch->uuid);
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


	#sleep 30;

	$ch->wait_for_receive(4);

	my @msgs = $ch->messages(); # blocks [default 4 sec] until messages arrive, pass a false argument to not block

	use Data::Dumper;
	#print STDERR "Received: ".Dumper(\@msgs) if @msgs;
	if(@msgs)
	{
		info "$0: Received msg '$_->{data}'\n" foreach @msgs;
	}
	else
	{
		debug "$0: Did not receive any message\n";
	}
	
	info "Disconnect from $ENV{REMOTE_ADDR}\n";
}
else
{
	# create a tcp connection to the specified host and port
	my $handle = IO::Socket::INET->new(Proto     => "tcp",
					PeerAddr  => $host,
					PeerPort  => $port)
		|| die "can't connect to port $port on $host: $!";

	$handle->autoflush(1);       # so output gets there right away

	#print STDERR "[Connected to $host:$port]\n";

	$ENV{REMOTE_ADDR} = $host;
	print STDERR "Connect to $ENV{REMOTE_ADDR}\n";

	#my $worker = HashNet::MP::SocketWorker->new(sock => $handle, no_fork => 1);
	my $worker = HashNet::MP::SocketWorker->new(sock => $handle);

	$worker->wait_for_start;

	my $env = $worker->create_envelope("Hello, World", to => '58b4bd86-463a-4383-899c-c7163f2609b7'); #3c8d9969-4b58-4814-960e-1189d4dc76f9');

	$worker->outgoing_queue->add_row($env);

	$worker->wait_for_send;

	$worker->stop;

	print STDERR "Disconnect from $ENV{REMOTE_ADDR}\n";
}
