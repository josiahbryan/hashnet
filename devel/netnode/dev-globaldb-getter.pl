#!/usr/bin/perl
use common::sense;
use lib 'lib';

use HashNet::MP::GlobalDB;
use HashNet::MP::ClientHandle;
use HashNet::Util::Logging;

my $ch  = HashNet::MP::ClientHandle->setup(log_level => 0);
my $eng = HashNet::MP::GlobalDB->new($ch);

trace "$0: Waiting a second for any messages to come in\n";
$ch->wait_for_receive(msgs => 1, timeout => 4, speed => 1);

my $key = @ARGV == 1 ? shift @ARGV : 'test';

trace "$0: Gettting $key\n";
my %data = $eng->get($key);

trace "$0: Got '$key': ".Dumper(\%data);

print $data{data}, "\n";

trace "$0: Done\n";

