#!/usr/bin/perl

use common::sense;

use IO::Socket;
my $remote = IO::Socket::INET->new(
			Proto    => "tcp",
			PeerAddr => "localhost",
			PeerPort => "8051",
		)
|| die "can't connect to 8051 PORT on localhost";

print $remote "GET /db/tr_stream?node_uuid=5602d6b4-046b-11e2-81a8-a1ac7fe9ec21 HTTP/1.0\n\n";

my $boundary = undef;
my $got_boundary = 0;
while (!$got_boundary && ($_ = <$remote>))
{
	if(/multipart\/x-mixed-replace/)
	{
		$boundary =~ /boundary="?.*"?$/;
		print "Boundary: $boundary\n";
		$got_boundary = 1;
	}
	else
	{
		#print "Not boundary:[$_]\n";
	}
}

my @buffer = ();
my $hit_page = 0;
while(<$remote>)
{
	push @buffer, $_;
	if(/--$boundary/)
	{
		shift @buffer while $buffer[0] =~ /^\s*[\r\n]+$/;
		shift @buffer if $buffer[0] =~ /--$boundary/;
		#print "[[$buffer[0]]]\n\n\n";
		shift @buffer while $buffer[0] =~ /^\s*[\r\n]+$/;
		my $ctype = undef;
		if($buffer[0] =~ /content-type: (.*)$/i)
		{
			$ctype = $1;
			shift @buffer;
		}
		shift @buffer while $buffer[0] =~ /^[\r\n]+$/;
		
		pop @buffer if @buffer[$#buffer] =~ /--$boundary/;
		pop @buffer while $buffer[$#buffer] =~ /^\s*[\r\n]+$/;
		
		#shift @buffer; shift @buffer; pop @buffer; pop @buffer;
		print "$ctype [",join("",@buffer),"]\n" if @buffer;
		@buffer = ();
	}
}
