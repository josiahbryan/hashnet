#!/usr/bin/perl
use common::sense;
use lib '.';
use HashNet::StorageEngine;
my $eng = HashNet::StorageEngine->new(
	config  => '/tmp/test/1/peers.cfg',
	db_root => '/tmp/test/1/db',
);
my $hash = $eng->list;
print "$0: Loading and re-storing all keys so they get converted to 'network byte order' on disk (see Storable module) ...\n";
$eng->begin_batch_update;
$eng->put($_, $hash->{$_}) foreach keys %$hash;
$eng->end_batch_update;
print "$0: Restore done\n";
