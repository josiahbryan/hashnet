#!/usr/bin/perl
use common::sense;
use lib 'lib';

use HashNet::MP::ClientHandle;
use HashNet::MP::AutoUpdater;
use Getopt::Std;

my %opts;
getopts('f:v:a:', \%opts);

my $file = $opts{f};
my $app  = $opts{a} || $file;
my $ver  = $opts{v} || 0.01;

if(!$file)
{
	die "Usage: $0 -f file [-a app] [-v ver]\n";
}

my $ch = HashNet::MP::ClientHandle->setup();

HashNet::MP::AutoUpdater->send_update(
	ch   => $ch,
	ver  => $ver,
	file => $file,
	app  => $app,
);

$ch->wait_for_send;
$ch->stop;
