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

my $att_len = (1024 * 1024 * 8);
my $max = 512;
my $time = time();
my $len = 0;
$len += $ch->sw->send_message({uuid => $_.'.1-'.$time, "data" => $_}, '#' x $att_len) for 1..$max;

$ch->sw->wait_for_ack($_.'.1-'.$time) for 1..$max;

$len = $att_len * $max;# + length($_.'.1-'.$time.'data'.$_) * $max;

my $time_d = time - $time;
my $bytes_sec = $len / ($time_d <= 0 ? 1 : $time_d);

my $time = time();
# $ch->sw->send_message({uuid => $_.'.2-'.$time, "data" => $_}) for 1..$max;
# $ch->sw->wait_for_ack(         $_.'.2-'.$time) for 1..$max;


#$ch->sw->send_message({uuid => 'test', 'data'=>'hello'}, 'a' x 512);

#$ch->destroy_app;
$ch->stop;


trace "$0: Done\n";
trace "$0: Sent ".sprintf("%.02f MB", $len / 1024 / 1024)." in ".sprintf("%.02fs", $time_d)." at a rate of ".sprintf("%.02f MB/sec", $bytes_sec / 1024 / 1024)."\n";

