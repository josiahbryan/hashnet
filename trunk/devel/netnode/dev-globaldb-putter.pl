#!/usr/bin/perl
use common::sense;
use lib 'lib';

use HashNet::MP::GlobalDB;
use HashNet::MP::ClientHandle;
use HashNet::Util::Logging;
use File::Slurp qw/:std/;

use Getopt::Std;

my %opts;
getopts('lh:k:', \%opts);

my $key = $opts{k} ? $opts{k} : (@ARGV ? shift @ARGV : 'test');
my $val = $opts{v} ? $opts{v} : (@ARGV ? shift @ARGV : undef);
my $logging = $opts{l} ? 99 :0;
my $hosts = [ split /,/, ($opts{h} || 'localhost:8031') ];

my $ch  = HashNet::MP::ClientHandle->setup(hosts => $hosts, log_level => $logging);
my $eng = $ch->globaldb;

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

#trace "$0: Waiting a second for any messages to come in\n";
$ch->wait_for_receive(msgs => 1, timeout => 1, speed => 1);

trace "$0: Done\n";

$ch->destroy_app();


