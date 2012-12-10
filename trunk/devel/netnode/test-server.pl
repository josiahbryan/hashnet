#!/usr/bin/perl -w

use lib 'lib';

{package MyPackage;
	use Data::Dumper;
	
	use base qw(Net::Server::PreFork);
	
	use common::sense;
	use HashNet::MP::SocketWorker;
	
	my $node_info = 
	{
		uuid => '3c8d9969-4b58-4814-960e-1189d4dc76f9',
		name => 'Test Server',
		ver  => '0.01',
	};
	
	sub process_request
	{
		my $self = shift;
		
		$ENV{REMOTE_ADDR} = $self->{server}->{peeraddr};
		#print STDERR "Connect from $ENV{REMOTE_ADDR}\n";
		
		#HashNet::MP::SocketWorker->new('-', 1); # '-' = stdin/out, 1 = no fork
		
		HashNet::MP::SocketWorker->new(
			node_info	=> $node_info,
			sock		=> $self->{server}->{client},
			no_fork		=> 1
		);
		
		#print STDERR "Disconnect from $ENV{REMOTE_ADDR}\n";
	
		
	# 	while (<STDIN>)
	# 	{
	# 		s/[\r\n]+$//;
	# 		print "You said '$_'\015\012"; # basic echo
	# 		last if /quit/i;
	# 	}
	}
	
	my $obj = MyPackage->new(port => 8031, ipv => '*');
	$obj->run();#port => 160, ipv => '*');
};

