#!/usr/bin/perl

use Test::More;

use common::sense;
use lib '../lib';
use lib 'lib';
use HashNet::MP::LocalDB;

use Data::Dumper;

is(HashNet::MP::LocalDB->indexed_handle(), undef, "indexed_handle ignores empty args");

my $handle = HashNet::MP::LocalDB->handle;

# delete $handle->{test}->{table1};
#
#my $handle2 = HashNet::MP::LocalDB->handle("/tmp/test$$.dat");
# my $table = HashNet::MP::LocalDB->indexed_handle('/test/table1', $handle2);
# is($handle->{test}->{table1}, undef, "indexed_handle used the alternate handle");
# ok($handle2->{test}->{table1}, "indexed_handle used the alternate handle, check 2");
#
# undef $handle2;
# undef $table;
# unlink("/tmp/test$$.dat");

#$handle->{test}->{table1} ||= {};
#my $table = HashNet::MP::LocalDB->indexed_handle($handle->{test}->{table1});
my $table = HashNet::MP::LocalDB->indexed_handle('/test/table1');

ok(defined $table->shared_ref->data->{cnt}, "auto-create table ref from string");

$table->clear;
#print Dumper $handle;

my $row1 = {
	name => 'foobar',
	age => 23,
};

my $row2 = {
	name => 'framitz',
	age => 19,
};

$table += $row1; # implicitly tested if next is() fails

$table->set_index_keys(qw/name/);
is($table->index->{name}->{foobar}->{1}, 1, "rebuild index on set_index_keys()");

my $dbm_ref = $table->add_row($row2);
is($table->index->{name}->{framitz}->{2}, 1, "index on insert");

#ok(UNIVERSAL::isa($dbm_ref, 'DBM::Deep'), "add_row() returns a blessed DBM::Deep ref");

is($table->cur_id, 2, "id counter increments");

my $n_foo = $table->by_key(name => 'foobar');
is($n_foo->{id}, $row1->{id}, "lookup by name");

my $n19 = $table->by_key(age => 19);
is($n19->{id}, $row2->{id}, "lookup by age (auto_index)");

#print Dumper $handle, $table, $n19, $row2;
#delete $handle->{test};

my @list = @{$table->list};
is(scalar @list, 2, "list() returns 2 rows");

my @list = @{$table->list('age')};
is($list[0]->{id}, $row2->{id}, "list('age') sorts correctly");

my $ref = $table->del_row($row1);
ok(defined $ref, "delete row returned correctly");

my $ref = $table->by_key(name => 'foobar');
is($ref, undef, "search for deleted name undef");

is($table->by_id(1), undef, "search by id for deleted row undef");

is($table->by_key(name => 'framitz')->{id}, $row2->{id}, "del_row didn't clobber index for other name");

$table->clear;
is($table->shared_ref->data->{cnt}, 0, "clear() resets count");

is($table->by_id(2), undef, "search by id for row 2 undef - clear() deleted data");

# Recreate row1/2 because the contents were deleted by clear()
$row1 = {
	name => 'foobar',
	age => 23,
};

$row2 = {
	name => 'framitz',
	age => 19,
};

my @batch = ($row1, $row2);
$table->add_batch(\@batch);

is($table->by_key(name => 'foobar')->{id}, $row1->{id}, "lookup by name after add_batch");
is($table->by_key(name => 'framitz')->{id}, $row2->{id}, "lookup by name after add_batch 2");

$table->del_batch(\@batch);

is($table->by_key(name => 'foobar'), undef, "lookup by name after del_batch");
is($table->by_key(name => 'framitz'), undef, "lookup by name after del_batch 2");

done_testing();
