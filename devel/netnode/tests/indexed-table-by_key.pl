#!/usr/bin/perl

use Test::More;

use common::sense;
use lib '../lib';
use lib 'lib';
use HashNet::MP::LocalDB;

use Data::Dumper;

my $table = HashNet::MP::LocalDB->indexed_handle('/test/table1');

$table->clear;
#print Dumper $handle;

my $row1 = {
	name => 'foobar',
	age => 19,
};

my $row2 = {
	name => 'framitz',
	age => 19,
};

my $row3 = {
	name => 'framitz',
	age => 21,
};

$table->add_row($row1);
$table->add_row($row2);
$table->add_row($row3);

my $n_foo = $table->by_key(name => 'framitz');
is($n_foo->{id}, $row2->{id}, "lookup by name 'framitz'");

my @results = $table->by_key(name => 'framitz', age => 19);
is(scalar @results, 1, "lookup by name 'framitz' and age 19 returns 1 result");
is($results[0]->{id}, $row2->{id}, "lookup by name 'framitz' and age 19 returns correct row ID");

my $n_foo = $table->by_key(age => 21);
is($n_foo->{id}, $row3->{id}, "lookup by age 21");

my @results = $table->by_key(age => 19);
is(scalar @results, 2, "lookup by age 19 returns 2 results");

#print Dumper $table;

done_testing();