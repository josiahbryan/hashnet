#!/usr/bin/perl

use Test::More;

use common::sense;
use lib '../lib';
use lib 'lib';
use HashNet::MP::GlobalDB;
use File::Path;
use File::Path qw/mkpath/;
use Time::HiRes qw/sleep/;
use File::Slurp;

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

# Test datatype storage
my $img = "hashnet-logo.png";
$img = "../$img" if !-f $img;
my %data_types = (
	data_bin => scalar(read_file($img)),
	data_ref => { $test_key => $test_val },
	data_int => int(rand() * 100),
	data_big => scalar(read_file(\*DATA)),
	data_str => 'a' x 100_000,
);

#die Dumper \%data_types;

foreach my $type (keys %data_types)
{
	my $data = $data_types{$type};
	$gdb->put($type, $data);
	if(!ref $data)
	{
		is($gdb->get($type), $data, "put/get $type");
	}
	else
	{
		# Note: Assuming hashref
		foreach my $key (keys %$data)
		{
			is($gdb->get($type)->{$key}, $data->{$key}, "put/get $type, key '$key'");
		}
	}
}


# Test delete_disk_cache
ok(-d $db_file,  "$db_file is directory");
HashNet::MP::GlobalDB->delete_disk_cache($db_file);
ok(!-d $db_file, "delete_disk_cache deletes $db_file");


HashNet::MP::LocalDB->dump_db($db_file);

done_testing();


__DATA__
Lorem ipsum dolor sit amet, consectetur adipiscing elit. Nunc quis diam a ligula commodo accumsan. Fusce pharetra, massa ac porttitor dictum, turpis nisl dapibus odio, ut tempus turpis ante et odio. Vestibulum ullamcorper tincidunt accumsan. Etiam turpis lacus, porta et interdum vitae, commodo in enim. Fusce ac purus in nulla semper aliquam vitae ac erat. Praesent dui leo, vehicula a porttitor scelerisque, eleifend sit amet erat. Donec arcu nisl, pulvinar id tincidunt iaculis, varius eget tortor. Vivamus vitae purus enim. Maecenas ligula lorem, tempus ac ultricies vel, tempus id metus. Vivamus egestas luctus purus, ut suscipit lorem sodales ut. Etiam eu velit vitae neque aliquam eleifend ac ac nibh.

Praesent sem tellus, lacinia nec pellentesque quis, commodo ultricies leo. Duis ultricies enim sit amet magna molestie egestas. Quisque semper faucibus metus eu consectetur. Donec accumsan purus at erat hendrerit laoreet. Suspendisse eget molestie nulla. In elit nisl, lacinia vel molestie at, vulputate id orci. Nunc convallis faucibus sem sodales auctor. Aenean vitae nisi ut dolor interdum sodales.

Sed consectetur vulputate ligula sit amet vehicula. In magna sapien, cursus id rutrum sit amet, rutrum non diam. Nam enim quam, interdum vitae elementum sit amet, semper vitae purus. Suspendisse ultrices bibendum lobortis. Aliquam elementum sapien eu dui rutrum euismod. Etiam lacus risus, tincidunt sed volutpat vitae, ultrices sit amet dui. Aenean vulputate elementum scelerisque. Cras et felis id quam feugiat consectetur. Nullam et diam ut mauris adipiscing laoreet sed at ante. Cras ut felis erat, ac commodo sapien.

Proin gravida, tellus nec dictum egestas, nisi nulla pharetra augue, et consectetur dui dolor vitae odio. Vestibulum dictum malesuada lacinia. Curabitur ac ipsum mauris. Vivamus non convallis nibh. Mauris pharetra metus eget justo luctus porttitor. Etiam egestas turpis vel purus molestie rutrum. Sed laoreet justo interdum eros viverra in blandit turpis viverra. Fusce fringilla ultrices tortor, ac ornare purus convallis non.

Aliquam sem nisl, sodales ut ullamcorper eget, interdum quis est. Curabitur semper accumsan felis at porta. In et quam in arcu tristique pellentesque et sit amet urna. Ut at ante felis, id tempor felis. Pellentesque habitant morbi tristique senectus et netus et malesuada fames ac turpis egestas. Praesent justo risus, ultricies eu molestie nec, pulvinar a neque. Pellentesque feugiat erat tortor. Aenean lectus ligula, dapibus non consequat vel, gravida ac quam. Aliquam suscipit, turpis in ullamcorper tempor, eros augue rhoncus nisi, vitae vestibulum nisi libero elementum nunc. Fusce condimentum enim eget felis feugiat varius. Nullam non turpis tellus. Donec aliquam vestibulum erat, id consectetur augue aliquet quis. Sed nec dignissim purus.

Pellentesque vel ullamcorper est. Aenean eget tortor dui, molestie hendrerit elit. Sed volutpat dapibus velit porta egestas. Duis ultricies nisl sit amet ante dignissim in convallis lectus vestibulum. Nunc vehicula mollis orci ut bibendum. Duis at eros justo. Maecenas fermentum leo vitae felis semper suscipit et in quam. Integer volutpat libero quis enim pretium egestas. Ut orci libero, condimentum vel varius ut, malesuada non orci. Nulla id mauris tortor, interdum dignissim neque. Nam ac libero sapien, vitae tempus ante. Donec nec justo hendrerit massa iaculis ultricies. Proin vulputate vestibulum lorem, nec ultrices velit tempus quis. Proin faucibus consequat dignissim.

Fusce posuere ultricies metus, non porttitor risus molestie a. Nunc ac massa felis, eu lobortis est. Curabitur accumsan fermentum pulvinar. Donec eget nibh nec lorem fringilla laoreet. Ut ut faucibus dolor. Suspendisse tincidunt tincidunt sollicitudin. Donec sem nisi, faucibus pharetra mollis in, egestas id augue. Praesent dapibus sem sit amet lorem egestas ut dignissim magna egestas. Praesent auctor fringilla gravida. Praesent sed risus ante. Vivamus in mauris ante. Donec elementum imperdiet imperdiet. Donec eleifend rhoncus felis eu hendrerit. Fusce dapibus ornare risus vitae porttitor.

Aliquam erat volutpat. Nunc vel lorem elit. Ut tempus nunc vel nisl pharetra consequat. Maecenas consectetur mi id dui congue vestibulum ut at lectus. Proin fermentum, risus id tincidunt scelerisque, dolor massa eleifend nulla, non placerat purus lectus pellentesque ligula. Nullam vestibulum ultricies accumsan. Pellentesque habitant morbi tristique senectus et netus et malesuada fames ac turpis egestas. Nullam et massa justo. Curabitur rhoncus dictum mauris, porttitor pretium arcu aliquet et. Phasellus posuere euismod odio, non volutpat odio facilisis eu. Suspendisse posuere lorem ac erat blandit non fringilla urna ultrices. Maecenas eget elit sit amet eros pretium pellentesque.

Nulla porttitor est ut tellus semper fringilla aliquam purus dictum. Nunc eget felis nunc, eget cursus neque. Aenean eget convallis risus. Mauris porta risus eget risus posuere ullamcorper. Maecenas et neque justo. Nulla nisl est, tempus a faucibus quis, cursus quis neque. Nunc ultricies laoreet velit eu molestie. Donec volutpat sapien in nunc fermentum sit amet scelerisque mauris accumsan. Maecenas metus dui, vestibulum quis venenatis consequat, accumsan quis ipsum. Pellentesque volutpat mollis turpis at porttitor. Aenean volutpat, tellus sit amet tempor malesuada, ipsum dolor adipiscing mauris, vel pellentesque enim sapien aliquet mi. Sed blandit eleifend felis, tempor aliquam metus gravida eget.

Suspendisse nec erat turpis. Phasellus non nisl neque. Duis et mattis diam. Etiam diam justo, elementum facilisis auctor vitae, posuere ac dolor. Pellentesque tincidunt, turpis cursus vulputate dapibus, mi quam bibendum tellus, non eleifend risus tellus eu neque. Suspendisse suscipit auctor ipsum, in adipiscing risus tincidunt et. Morbi sit amet tempor erat. Phasellus sed quam turpis, eu adipiscing purus. Proin suscipit, arcu vitae sagittis auctor, dui magna volutpat lacus, non vestibulum diam augue sit amet est. Praesent tempus adipiscing varius. Vivamus eleifend porttitor lacus. Cras eu dolor quam, eget pharetra purus. Vivamus mattis, diam id commodo tristique, lacus justo cursus quam, nec rhoncus eros elit at lectus. Cras iaculis leo ut erat scelerisque scelerisque.

Donec arcu ipsum, luctus at posuere eu, malesuada a dui. Praesent eget lacus ac massa aliquet accumsan. Nam vel justo augue, vel dapibus risus. Vivamus egestas scelerisque odio, non pretium urna varius in. Curabitur at lectus quis nisi tempor tempor eget sodales nisl. Vestibulum sed luctus massa. Nullam nec varius tortor. Curabitur at rhoncus elit. Vivamus eget ante mauris, sit amet euismod ligula. Donec volutpat lobortis cursus. Nulla facilisi. Nunc in lacus nec libero tristique ultricies ut ac lacus. Nunc tincidunt blandit lacus sit amet bibendum.

Sed convallis arcu et nunc sodales accumsan. Nunc faucibus, nulla nec varius gravida, est nunc tristique dolor, vitae rutrum ante neque id nisi. Suspendisse potenti. Sed malesuada tellus a leo bibendum viverra eu ac neque. Nunc id magna ut erat tincidunt congue. Ut blandit tortor a velit feugiat dictum. Donec magna nulla, laoreet nec consectetur id, dignissim ut augue.

In porttitor, arcu at tristique varius, mi nisl commodo dolor, sit amet vehicula tellus lectus at nisi. Integer erat turpis, dapibus faucibus porta posuere, iaculis id risus. Fusce ante nisl, cursus nec ultrices et, molestie quis quam. Donec tortor erat, pellentesque varius dictum ut, dapibus dignissim erat. Vivamus et libero libero, ut commodo urna. Suspendisse potenti. Donec non arcu in urna semper luctus. Curabitur at risus libero. Curabitur tincidunt adipiscing sodales. Integer turpis nisl, lobortis vel vestibulum id, semper sit amet dui. Aliquam nec mauris ac nibh rhoncus facilisis quis at orci.

Pellentesque vel lorem nisl. Class aptent taciti sociosqu ad litora torquent per conubia nostra, per inceptos himenaeos. Donec mattis risus non lectus congue auctor. Ut sit amet tortor eget orci pharetra pulvinar. Aliquam sollicitudin quam vitae orci convallis accumsan. Cras pellentesque tempor urna sit amet ullamcorper. Cras vestibulum mollis libero, quis egestas nisl placerat id. Vestibulum aliquam nibh et eros rhoncus tristique. Mauris ut commodo nibh. Lorem ipsum dolor sit amet, consectetur adipiscing elit. Cras nec lectus nec mi molestie gravida at at quam. Sed id pretium enim. Nulla dui augue, tempor id viverra eu, laoreet in sem. Donec leo velit, varius a adipiscing quis, convallis at mi.

Sed sit amet elit dolor. Nam facilisis libero bibendum turpis malesuada at dignissim nisi iaculis. Maecenas lacinia lorem nec nibh imperdiet dignissim. Sed tortor diam, egestas non scelerisque ut, congue sit amet arcu. Nam lectus arcu, blandit non semper et, volutpat sed purus. Duis mattis lacus et ligula facilisis ac iaculis ante semper. Fusce convallis iaculis dictum. Sed et ipsum sit amet mi tempus volutpat. Proin id metus id lacus tempus pharetra non eget enim. Quisque lacinia, neque non dictum tempor, leo leo elementum mi, et ornare quam ligula sit amet neque. Donec vulputate vestibulum aliquet.

Integer egestas quam eget odio euismod vitae posuere sapien ultrices. Maecenas ullamcorper tincidunt est, non congue leo facilisis a. Nulla vel leo malesuada nisl sagittis imperdiet. Nullam vel mauris ut neque dapibus egestas. Integer lacinia dolor id felis eleifend in tincidunt augue dictum. Phasellus adipiscing vehicula lorem eu porttitor. Fusce sagittis, dolor at placerat auctor, neque arcu pharetra justo, vitae volutpat mauris lacus et tortor. Morbi in ipsum ut enim pharetra elementum. Sed malesuada varius nisl eget elementum.

Donec euismod velit nibh. Aliquam nisi libero, egestas eget molestie nec, viverra vel ligula. Sed ut est nec justo luctus adipiscing. Curabitur turpis libero, ornare eu adipiscing at, facilisis a nisi. Vivamus aliquam pharetra lorem in cursus. Aliquam placerat pulvinar diam tempus volutpat. Vivamus vel molestie odio. Suspendisse potenti. Donec tincidunt consequat magna, nec tristique quam aliquet ac. Duis risus turpis, pulvinar id aliquam et, tincidunt vel leo. Donec adipiscing commodo enim, eu dictum neque molestie at. In hac habitasse platea dictumst. Class aptent taciti sociosqu ad litora torquent per conubia nostra, per inceptos himenaeos. Nulla id tortor non lorem fermentum accumsan. Etiam aliquam, risus non vestibulum venenatis, mauris justo fringilla dolor, eget gravida lectus eros ut sapien.

Maecenas convallis aliquam ornare. Class aptent taciti sociosqu ad litora torquent per conubia nostra, per inceptos himenaeos. Nunc commodo semper ultricies. Nullam at nisi nibh, vel mattis quam. Phasellus neque leo, sagittis sed volutpat eget, blandit et massa. Aenean auctor, dolor ornare fringilla pretium, odio ante aliquam lorem, eu suscipit magna neque eu ligula. Curabitur non mattis massa. Nunc tristique lobortis sollicitudin. Maecenas in metus mattis tellus facilisis auctor. Sed blandit lacus nec odio elementum tincidunt.

Ut sed nibh metus. Aliquam accumsan quam vel eros gravida eget pulvinar mi tempor. Ut turpis justo, blandit non mattis non, eleifend in leo. Nulla facilisi. Maecenas condimentum imperdiet lectus, vel vestibulum odio fermentum vitae. Nam sed est id nibh malesuada interdum. Etiam eleifend lacinia diam, sed convallis tortor adipiscing nec. Suspendisse ut urna vitae urna sodales scelerisque in nec nisl. Quisque eu dolor et quam ultricies imperdiet. Aenean non magna quam, ultricies lacinia sapien. Phasellus lacus tortor, rhoncus ac elementum vel, adipiscing a ante. Aenean vestibulum mollis cursus. Integer turpis felis, accumsan sit amet aliquam ut, luctus pharetra quam.

Donec sodales adipiscing lacus, sit amet fringilla dui hendrerit ut. Phasellus condimentum volutpat velit, vel pellentesque orci vehicula ac. Mauris placerat cursus luctus. Maecenas at mi augue, sed ultrices felis. Fusce dictum dolor dui. Cras at sapien tortor. Donec fringilla accumsan orci vel lacinia. Proin ut massa erat, non commodo lorem. Sed vel tortor adipiscing dui pretium tempus. Etiam viverra vulputate arcu et aliquam. Mauris nulla lacus, condimentum sed lobortis in, lobortis tempor odio.

Ut ullamcorper, arcu eu sagittis dignissim, augue orci vulputate dui, id bibendum felis ipsum in enim. Donec lacus ligula, aliquam eu sagittis vehicula, sagittis ut erat. Nam eget ipsum magna. Aliquam enim arcu, gravida congue vehicula vel, eleifend nec tortor. Pellentesque non accumsan purus. Duis ultricies fermentum tellus, sit amet condimentum elit dignissim ut. Nam placerat lectus vel diam lacinia ultricies. Suspendisse luctus consequat sodales. Aenean eget metus est, sit amet interdum leo.

Fusce posuere sodales orci. Mauris ut nibh eu lacus vestibulum luctus. Phasellus eu lectus quam, quis hendrerit quam. Phasellus lorem ipsum, viverra ut sodales a, posuere at felis. Aliquam nec felis sit amet lectus elementum volutpat quis ac sem. Nulla ac faucibus ipsum. Nam non sagittis mi. Proin posuere dignissim ipsum, a convallis purus accumsan et. Nam elit sapien, tempus non rutrum sed, volutpat aliquam metus. Pellentesque non dui sed orci placerat bibendum. Praesent et elit et lectus laoreet porttitor sit amet vitae neque. Pellentesque in vulputate orci. Vestibulum ante ipsum primis in faucibus orci luctus et ultrices posuere cubilia Curae; Etiam eget erat vel dolor dignissim tincidunt in molestie metus. Phasellus lectus risus, commodo a pretium nec, convallis id mi. Pellentesque habitant morbi tristique senectus et netus et malesuada fames ac turpis egestas.

Class aptent taciti sociosqu ad litora torquent per conubia nostra, per inceptos himenaeos. Donec mauris sem, ullamcorper eu porta quis, molestie non nunc. Class aptent taciti sociosqu ad litora torquent per conubia nostra, per inceptos himenaeos. Donec id velit nulla. Maecenas ac nulla velit, et auctor neque. Lorem ipsum dolor sit amet, consectetur adipiscing elit. Ut ut urna lectus, rhoncus blandit velit. Fusce malesuada dapibus facilisis. Morbi ac massa enim, nec pretium elit. Suspendisse tincidunt vulputate tempor. Sed lorem arcu, porttitor id tincidunt nec, placerat tristique augue. Quisque a malesuada nisi. Suspendisse ut risus purus, at pharetra turpis. Suspendisse sed quam ut mi facilisis viverra eu vitae justo.

Quisque hendrerit, velit eu rhoncus egestas, nisi turpis pretium nunc, semper consectetur orci diam vitae lorem. Nullam metus nulla, interdum ultricies sodales dapibus, mollis ac lorem. In rhoncus tempus metus, ac venenatis arcu eleifend rhoncus. Nulla mattis lacinia faucibus. Aenean congue dolor pretium massa mattis quis blandit ante rhoncus. Nulla facilisi. Integer porttitor, libero ac suscipit tempor, quam justo viverra erat, at faucibus magna dui suscipit leo. Cras porta ipsum vitae sapien scelerisque lobortis. Nunc sodales feugiat euismod. Suspendisse ut justo enim, a suscipit mi. Vestibulum in lorem diam, in pellentesque dui. Nam tempus, urna vitae congue eleifend, sem lorem scelerisque lorem, nec posuere est nisi ut magna.

Etiam tristique magna orci, nec venenatis ligula. Maecenas et leo sed lectus sodales sodales. Nullam sit amet elit nec massa blandit suscipit. Integer in consequat turpis. Quisque adipiscing libero bibendum lorem sagittis dictum. In porta nulla eget tellus gravida sit amet fermentum lectus consectetur. Etiam non est non diam suscipit sagittis. Suspendisse neque velit, scelerisque eu iaculis eu, vulputate nec nibh. Mauris metus orci, tincidunt quis tincidunt nec, dapibus gravida lacus. Pellentesque habitant morbi tristique senectus et netus et malesuada fames ac turpis egestas. Suspendisse tristique sapien non ligula blandit tempus. Etiam ut dui diam. Nulla commodo fringilla turpis, nec egestas lectus tempus id. Sed sit amet massa leo.