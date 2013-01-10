#!/usr/bin/perl
use common::sense;
use lib 'lib';

use HashNet::MP::GlobalDB;
use HashNet::MP::ClientHandle;
use HashNet::Util::Logging;

my $ch  = HashNet::MP::ClientHandle->setup();
my $eng = HashNet::MP::GlobalDB->new($ch);

my ($key, $val) = @ARGV == 2 ? @ARGV : ();

$key ||= 'test';
if(!defined $val)
{
	$val = `date`;
	$val =~ s/[\r\n]//g;
}

trace "$0: Putting $key => '$val'\n";
$eng->put($key => $val);

trace "$0: Waiting a second for any messages to come in\n";
$ch->wait_for_receive(msgs => 1, timeout => 4, speed => 1);

trace "$0: Done\n";

