#!/usr/bin/perl
use strict;
use lib 'lib';
use HashNet::MP::LocalDB;
use Data::Dumper;

my $queue_out = HashNet::MP::LocalDB->indexed_handle('/queues/outgoing');

$queue_out->add_row({
	dest => 'f1662c48-40b4-11e2-8173-daca617bcecf',
	hash => {
		dest => 'f1662c48-40b4-11e2-8173-daca617bcecf',
		msg  => 'MSG_HELLO',
		text => 'Praise God! Prov 18.22',
	},
});

print Dumper( HashNet::MP::LocalDB->handle );