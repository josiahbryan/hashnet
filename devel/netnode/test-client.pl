#!/usr/bin/perl -w

use lib 'lib';

use strict;
use common::sense;
use HashNet::MP::SocketWorker;
use HashNet::MP::LocalDB;
use HashNet::MP::ClientHandle;

use IO::Socket;

my ($host, $port) = @ARGV;

$host = 'localhost' if !$host;
$port = 8031 if !$port;

$HashNet::MP::LocalDB::DBFILE = "$0.db";

if(1)
{
	my $ch = HashNet::MP::ClientHandle->new($host, $port);


	$ENV{REMOTE_ADDR} = $host;
	print STDERR "Connected to $ENV{REMOTE_ADDR}\n";

	#$ch->send("Test of ClientHandle");
	$ch->send("Bouncy Bouncy", to => $ch->uuid);
	
#	my $worker = $ch->sw;
	
#	$worker->wait_for_start;

#	my $env = $worker->create_envelope("Hello, World", to => '58b4bd86-463a-4383-899c-c7163f2609b7'); #3c8d9969-4b58-4814-960e-1189d4dc76f9');
# 
# 	$worker->outgoing_queue->add_row($env);
# 
# 	$worker->wait_for_send;

#	$worker->stop;


	print STDERR "Disconnect from $ENV{REMOTE_ADDR}\n";
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
