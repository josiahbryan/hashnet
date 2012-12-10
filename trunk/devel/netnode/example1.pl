#! /usr/bin/perl

use strict;
use warnings;
use IO::Socket;
use POSIX qw ( :sys_wait_h :fcntl_h );
use Errno qw ( EINTR EAGAIN );

my $testport = 8080;


# This is what runs in the child process
sub kidstuff {
    my $sock = shift;
    # Read and log whatever comes in
  BUFRD:
    while (1) {
	$! = 0;
	my $data;
	my $res = $sock->read($data, 99);
	# res: #chars, or 0 for EOF, or undef for error
	die "read failed on $!" unless defined($res);
	last BUFRD if $res == 0; # EOF
	print "Read($res): $data\n";
    }
}

$|=1;				# autoflush
my $listener = IO::Socket::INET->new (
				      LocalPort => $testport,
				      type => SOCK_STREAM,
				      Proto => 'tcp',
				      Reuse => 1,
				      Listen => 5,
				      );
if (!defined($listener)) {
    die "Failed to listen on port $testport: $!";
}

CLIENT: while (1) {
    my $client = $listener->accept();
    if (!defined($client)) {
	# Some kind of error
	if ($! == EINTR) {
	    print "Accept returned EINTR\n";
	    next CLIENT;
	}
	# If it's an undef other than EINTR, maybe not really a client,
	die "Accept error: $!";
    }

    # Read first line from client
    my $l1 = $client->getline();
    die "client read error $!" unless defined($l1);
    print "Server, first client line is $l1\n";

    # Now fork server
    my $kid = fork();
    die "Fork failed" unless defined($kid);
    if ($kid == 0) {
	print "Child $$ running\n";
	kidstuff($client);
	print "Child $$ complete, exiting\n";
	exit 0;
    }
    # Parent continues here.
    while ((my $k = waitpid(-1, WNOHANG)) > 0) {
	# $k is kid pid, or -1 if no such, or 0 if some running none dead
	my $stat = $?;
	print "Reaped $k stat $stat\n";
    }
}				# CLIENT: while (1)