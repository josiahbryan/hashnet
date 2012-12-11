#!/usr/bin/perl -w

use lib 'lib';

use strict;
use common::sense;
use HashNet::MP::SocketWorker;
use HashNet::MP::LocalDB;
	
use IO::Socket;

my ($host, $port) = @ARGV;

$host = 'localhost' if !$host;
$port = 8031 if !$port;

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

my $env = $worker->create_envelope("Hello, World", to => '3c8d9969-4b58-4814-960e-1189d4dc76f9');

$worker->outgoing_queue->add_row($env);

sleep 1; # wait for msgs to process

$worker->stop;

print STDERR "Disconnect from $ENV{REMOTE_ADDR}\n";
