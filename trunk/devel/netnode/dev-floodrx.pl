#!/usr/bin/perl
use common::sense;
use lib 'lib';

use HashNet::MP::GlobalDB;
use HashNet::MP::ClientHandle;
use HashNet::Util::Logging;
use Getopt::Std;

my %opts;
getopts('qh:k:', \%opts);

my $key = $opts{k} ? $opts{k} : (@ARGV ? shift @ARGV : 'test');
my $logging = $opts{'q'} ? 0 : 99;
my $hosts = [ split /,/, ($opts{h} || 'localhost:8031') ];

my $ch  = HashNet::MP::ClientHandle->setup(hosts => $hosts, log_level => $logging);
#my $eng = $ch->globaldb;


my $sock = $ch->sw->{sock};

#my $msg = "{\"val\":". ('a' x 100_000 }

#$ch->sw->send_message({uuid => '1-'.time(), "data"=>1}, 'a' x (1024 * 1024));
#$ch->sw->send_message({uuid => '3-'.time(), "data"=>2}, 'a' x (1024 * 1024));
#$ch->sw->send_message({uuid => '3-'.time(), "data"=>3}, 'a' x (1024 * 1024));

my $max = 1;
my $time = time();
$ch->sw->send_message({uuid => $_.'.1-'.$time, "data" => $_}, '#' x (1024 * 1024)) for 1..$max;
$ch->sw->wait_for_ack(         $_.'.1-'.$time) for 1..$max;

my $time = time();
$ch->sw->send_message({uuid => $_.'.2-'.$time, "data" => $_}) for 1..$max;
$ch->sw->wait_for_ack(         $_.'.2-'.$time) for 1..$max;


#$ch->sw->send_message({uuid => 'test', 'data'=>'hello'}, 'a' x 512);



trace "$0: Done\n";

