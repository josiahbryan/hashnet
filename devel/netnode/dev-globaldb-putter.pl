#!/usr/bin/perl
use common::sense;
use lib 'lib';

use HashNet::MP::GlobalDB;
use HashNet::MP::ClientHandle;
use HashNet::Util::Logging;
use File::Slurp qw/:std/;

my $ch  = HashNet::MP::ClientHandle->setup();
my $eng = HashNet::MP::GlobalDB->new($ch);

my ($key, $val) = @ARGV == 2 ? @ARGV : ();

$key ||= 'test';
if(!defined $val)
{
	$val = `date`;
	$val =~ s/[\r\n]//g;
}

if($val eq '-')
{
	trace "$0: Reading value for '$key' from STDIN...\n"; 
	$val = read_file(\*STDIN);
	trace "$0: Putting $key => ".length($val)." bytes of data\n";
}
else
{
	trace "$0: Putting $key => '$val'\n";
}
$eng->put($key => $val);

trace "$0: Waiting a second for any messages to come in\n";
$ch->wait_for_receive(msgs => 1, timeout => 4, speed => 1);

trace "$0: Done\n";

