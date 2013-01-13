#!/usr/bin/perl

use Test::More;

use common::sense;
use lib '../lib';
use lib 'lib';
use HashNet::MP::GlobalDB;
use File::Path;
use File::Path qw/mkpath/;
use Time::HiRes qw/sleep/;

use Data::Dumper;

# Necessary for is_lock_stale after fork to work
$SIG{CHLD} = 'IGNORE';

my $db_file = 'db.gdbasic';
$HashNet::MP::LocalDB::DBFILE = ".$db_file";

HashNet::MP::LocalDB->dump_db($db_file);
HashNet::MP::GlobalDB->delete_disk_cache($db_file);

# Mute logging output
$HashNet::Util::Logging::LEVEL = 0; #-t STDIN ? 999 : 0;
$HashNet::Util::Logging::ANSI_ENABLED = 1 if $HashNet::Util::Logging::LEVEL;

my $gdb = HashNet::MP::GlobalDB->new(db_root => $db_file);


# Test basic functions
my $dir = "/tmp/foobar$$";
my $file = "$dir/test";
mkpath($dir);
system("echo x > $file");
ok(!HashNet::MP::GlobalDB::is_folder_empty($dir), "is_folder_empty() correct false");
unlink($file);
ok(HashNet::MP::GlobalDB::is_folder_empty($dir),  "is_folder_empty() correct true");
rmtree($dir);

### elide_string not critical to test
### discover_mimetype tested implicitly with put() test below
 
is(HashNet::MP::GlobalDB::is_printable(chr(254)), 0, "chr(254) not printable");
is(HashNet::MP::GlobalDB::is_printable(chr(32)),  1, "chr(32)  is  printable");

ok(UNIVERSAL::isa($gdb->db_lock(), 'HashNet::MP::SharedRef'), "db_lock() valid shared ref");

# test sw() and ch() in globaldb-online.pl
is($gdb->sw_handle, 'HashNet::MP::SocketWorker', "sw_handle() returns class name if no ch()");

### test setup_message_listeners() in globaldb-online.pl

my $meta;
my $test_key = "test";
my $test_val = $$;
my $expected_mime = "text/plain";

# Test put() first before gen_db_archive() so there's data in the DB to archive 
$meta = $gdb->put($test_key => $test_val);
is(ref $meta, 'HASH', "put() returns hashref");
ok($meta->{timestamp} > 0, "put() returns timestamp > 0");
ok($meta->{editnum}   > 0, "put() returns editnum > 0");
ok($meta->{size}      > 0, "put() returns size > 0");
is($meta->{mimetype}, $expected_mime, "put() figures out mimetype");

# Check the offline functionality of _push_Tr
my $tr_table_handle = $gdb->{offline_tr_db};
is($tr_table_handle->size, 1, "_push_tr added 1 to offline_tr_db"); 

# Create an MD5 of the DB folder prior to the tar call
sub md5_folder { local $_ = `ls -lh \`find $db_file\` | md5sum`; s/[\r\n]//g; return $_ };
my $md5_before = md5_folder();
ok($md5_before, "m5sum on folder works ($md5_before)");

# Test gen_db_archive
my $file = $gdb->gen_db_archive();
ok($file, "gen_db_archive creates $file");
ok(-f $file, "$file exists");
rmtree($db_file);
ok(!-d $db_file, "$db_file deleted");

# Test apply_db_archive() using the MD5 created above and the current MD5
$gdb->apply_db_archive($file);
my $md5_after = md5_folder();
is($md5_before, $md5_after, "MD5 of folder '$db_file' matches after apply_db_archive"); 

# test db_root
is($gdb->db_root, $db_file, "db_root returns $db_file");

# Test begin_batch_update()
is($gdb->in_batch_update, 0, "not in in_batch_update prior to first call to begin_batch_update");
$gdb->begin_batch_update;
is($gdb->in_batch_update, 1, "begin_batch_update sets flag");

# Test put() within batch update mode
srand(time);
$test_val = int(rand() * 1000);
$gdb->put($test_key => $test_val);

my @batch = @{$gdb->{_batch_list} || []};
is(scalar @batch, 1, "put() honors batch_update");

# Test begin_batch_update() again
$gdb->begin_batch_update;
@batch = @{$gdb->{_batch_list} || []};
is(scalar @batch, 1, "redundant call to begin_batch_update doesnt erase _batch_list");

# Test end batch
$gdb->end_batch_update;
is($gdb->in_batch_update, 0, "end_batch_update resets flag");

# Test _push_tr offline mode in a batch
my $tr_table_handle = $gdb->{offline_tr_db};
is($tr_table_handle->size, 2, "_push_tr added 1 to offline_tr_db"); 

# Test _put_local_batch
my $test_key2 = 'hello';
my $test_val2 = int(rand() * 1000);
my $fake_batch = [
	{ key => $test_key, _key_deleted => 1 },
	{ key => $test_key2, val => $test_val2 }
];
$gdb->_put_local_batch($fake_batch);
my $val_get = $gdb->get($test_key);
ok(!defined $val_get, "_put_local_batch properly deleted $test_key");

is($gdb->get($test_key2), $test_val2, "_put_local_batch created $test_key2 with $test_val2");

# Test delete()
$gdb->delete($test_key2);
$val_get = $gdb->get($test_key2);
ok(!defined $val_get, "deleted $test_key2");


# Run tests on sanatize_key() and _process_key()
my %key_tests = (
	a1	=> 1,
	a	=> 1,
	'a?'	=> undef,
	'a../../..b' => 'a/b',
	'a b'	=> 1,
	'a.b'	=> 1,
);
foreach my $key (keys %key_tests)
{
	my $val = $key_tests{$key};
	$val = $key if $val == 1;
	undef $@;
	my $san_key = HashNet::MP::GlobalDB::sanatize_key($key);
	is($san_key, $val, "sanatize_key('$key') = ".(defined($val) ? "'$val'" : '(undef)'));
	if(!defined $val)
	{
		ok(defined $@, "Invalid key '$key' sets error message to '$@'");
	}
	
	undef $@;
	my $file = $gdb->_process_key($key);
	my ($data,$meta) = $gdb->_process_key($key);
	my $ex_data = $gdb->db_root . '/' . $san_key . '/data';
	my $ex_meta = $gdb->db_root . '/' . $san_key . '/meta';
	if($val)
	{
		is($file, $ex_data, "_process_key('$key') in scalar context returns '$ex_data'");
		is($data, $ex_data, "_process_key('$key') in list context returns ('$ex_data',..)"); 
		is($meta, $ex_meta, "_process_key('$key') in list context returns (..,'$ex_meta')");
	}
	else
	{
		ok(!defined $file, "_process_key('$key') for invalid key returns undef value in scalar context");
		ok(!defined $data, "_process_key('$key') for invalid key returns undef value in list context");
		ok(defined $@, "_process_key('$key') for invalid key sets error to '$@'");
	}
}

# Test get_meta
$test_val = int(rand() * 1000);
my $meta_good = $gdb->put($test_key => $test_val);
my $meta_test = $gdb->get_meta($test_key);

foreach my $key (keys %{$meta_good})
{
	is($meta_test->{$key}, $meta_good->{$key}, "get_meta() returns '$meta_good->{$key}' for '$key'");
}

# Basic test on offline _query_hubs
is($gdb->_query_hubs('foo'), 0, "_query_hubs correctly fails offline");

# Test get_all
my $test_val2 = int(rand() * 1000);
$gdb->put($test_key2 => $test_val2);

my $hash = $gdb->get_all();
is($hash->{'/'.$test_key},  $test_val,  "get_all() returns '$test_val' for /$test_key");
is($hash->{'/'.$test_key2}, $test_val2, "get_all() returns '$test_val2' for /$test_key2");

# Test get_all() with meta
$hash = $gdb->get_all('/', 1);
is($hash->{'/'.$test_key}->{data},  $test_val,  "get_all('/',1) returns '$test_val' for /$test_key");
is($hash->{'/'.$test_key2}->{data}, $test_val2, "get_all('/',1) returns '$test_val2' for /$test_key2");

my @keys = ($test_key, $test_key2);
foreach my $key (@keys)
{
	my $meta = $gdb->get_meta($key);
	my $data = $hash->{'/'.$key};
	foreach my $mk (keys %{$meta})
	{
		is($data->{$mk}, $meta->{$mk}, "get_all('/',1) returns meta value '$data->{$mk}' for meta key '$mk'");
	}
}

$hash = $gdb->get_all('test|hello');
is($hash->{'/'.$test_key},  $test_val,  "get_all('test|hello') returns '$test_val' for /$test_key");
is($hash->{'/'.$test_key2}, $test_val2, "get_all('test|hello') returns '$test_val2' for /$test_key2");

$hash = $gdb->get_all('test');
is($hash->{'/'.$test_key},    $test_val,  "get_all('test') returns '$test_val' for /$test_key");
ok($hash->{'/'.$test_key2} != $test_val2, "get_all('test') does not return '$test_val2' for /$test_key2");

$hash = $gdb->get_all('/test|hello');
is($hash->{'/'.$test_key},    $test_val,  "get_all('/test|hello') returns '$test_val' for /$test_key");
ok($hash->{'/'.$test_key2} != $test_val2, "get_all('/test|hello') does not return '$test_val2' for /$test_key2");

# Test locking
is($gdb->lock_key($test_key, timeout => 0.5, speed => 0.1), 1, "lock_key('$test_key') correctly locks");
is($gdb->lock_key($test_key, timeout => 0.5, speed => 0.1), 0, "lock_key('$test_key') correctly fails to lock");

my $lock_data = $gdb->get($test_key.'.lock');
is($lock_data->{locking_pid}, $$, "lock data for lock on '$test_key' returns pid $$");
ok(!defined $lock_data->{locking_uuid}, "no UUID in locking data defined in offline mode");

is($gdb->is_lock_stale($test_key), 0, "lock for '$test_key' not stale");
is($gdb->unlock_if_stale($test_key), 0, "unlock_if_stale('$test_key') fails because lock not stale");
is($gdb->unlock_key($test_key), 1, "unlock_key('$test_key')");

if(!fork)
{
	$gdb->lock_key($test_key);
	exit(0);
}
sleep 0.5;
is($gdb->is_lock_stale($test_key), 1, "lock for '$test_key' IS stale");
is($gdb->unlock_if_stale($test_key), 1, "unlock_if_stale('$test_key')");

# Test get failure
my $undef_key = 'foobar123';
my $bad_get = $gdb->get($undef_key);
ok(!defined $bad_get, "get('$undef_key') not defined");

# Test db_rev
my $rev = $gdb->db_rev();
ok($rev > 0, "db_rev() returns $rev in scalar context");

my ($rev2, $ts) = $gdb->db_rev();
is($rev2, $rev, "db_rev() in list context returns ($rev2, ...)");
ok($ts > 0, "db_rev() in list context returns timestamp");

# TODO: Add tests for different types of data:
# - Refs (Succeede), code refs (fail)
# - Binary (images, etc)
# - Plain text/scalars

# Test delete_disk_cache
ok(-d $db_file,  "$db_file is directory");
HashNet::MP::GlobalDB->delete_disk_cache($db_file);
ok(!-d $db_file, "delete_disk_cache deletes $db_file");


HashNet::MP::LocalDB->dump_db($db_file);

done_testing();