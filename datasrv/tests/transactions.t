#!/usr/bin/perl
use strict;
use Test::More;
use lib '..';

#BEGIN { print "$0 begin\n" }

BEGIN { use_ok('HashNet::StorageEngine::TransactionRecord'); };

# Make logging quiet so we can read test output more easily
use HashNet::Util::Logging;
$HashNet::Util::Logging::LEVEL = 0;

use DBM::Deep;
use Storable qw/freeze thaw/;
use JSON qw/encode_json decode_json/;

#my $file = "./devel/viz/img/rectangle.png";
my $img = "www/images/hashnet-logo.png";
#my $img = "test-img.jpg";
my $file = "../" . $img;
if(!-f $file)
{
	$file = $img;
}

my $data = `cat $file`;
my $len = length($data);

#print "len of data: $len\n";
#die "Cannot read file: $file" if $len <= 0;
if($len <= 0)
{
	# Fill in a simple non-printable (well, outside :print: range) character
	$data = chr(244);
}

$HashNet::StorageEngine::TransactionRecord::ENABLE_BASE64_ENCODING = 0;
my $key = 'bintest';
my $val = $data;
my $tr_simple = HashNet::StorageEngine::TransactionRecord->new('MODE_KV', $key, $val, 'TYPE_WRITE');

my @batch_list;
push @batch_list, {key=>$key, val=>$data};
my $tr_batch = HashNet::StorageEngine::TransactionRecord->new('MODE_KV', '_BATCH', \@batch_list, 'TYPE_WRITE_BATCH');

# Test simple key/value pair
{
	my $hash = $tr_simple->to_hash;
	
	my $tr2 = HashNet::StorageEngine::TransactionRecord->from_hash($hash);
	is($tr2->data, $data, "Simple Key/Value");
}

# Test a batch list
{
	my $hash = $tr_batch->to_hash;
	
	my $tr2 = HashNet::StorageEngine::TransactionRecord->from_hash($hash);
	is($tr2->data->[0]->{val}, $data, "Batch List");
}

# Test simple key/value pair with base64
{
	# Enable base64 encoding
	$HashNet::StorageEngine::TransactionRecord::ENABLE_BASE64_ENCODING = 1;

	my $hash = $tr_simple->to_hash;
	
	my $tr2 = HashNet::StorageEngine::TransactionRecord->from_hash($hash);
	is($tr2->data, $data, "Base64 Simple Key/Value");
}

# Test a batch list
{
	# Enable base64 encoding
	$HashNet::StorageEngine::TransactionRecord::ENABLE_BASE64_ENCODING = 1;

	my $hash = $tr_batch->to_hash;
	
	my $tr2 = HashNet::StorageEngine::TransactionRecord->from_hash($hash);
	is($tr2->data->[0]->{val}, $data, "Base64 Batch List");
}

# Test freeze/thaw
{
	$HashNet::StorageEngine::TransactionRecord::ENABLE_BASE64_ENCODING = 0;
	
	my $bytes = freeze($tr_simple->to_hash);
	
	my $tr2 = HashNet::StorageEngine::TransactionRecord->from_hash(thaw($bytes));
	is($tr2->data, $data, "Freeze/thaw");
}

# Test freeze/DBM::Deep/thaw
{
	$HashNet::StorageEngine::TransactionRecord::ENABLE_BASE64_ENCODING = 0;
	
	my $db_file = '/tmp/03'.$$.'.db';
	my $db = DBM::Deep->new(
		file => $db_file,
		type => DBM::Deep->TYPE_ARRAY
	);
	$db->[0] = $tr_simple->to_hash;
	undef $db;
	
	my $db2 = DBM::Deep->new(
		file => $db_file,
		type => DBM::Deep->TYPE_ARRAY
	);
	
	my $tr2 = HashNet::StorageEngine::TransactionRecord->from_hash($db2->[0]);
	is($tr2->data, $data, "DBM::Deep Storage");
	
	unlink($db_file);
}

# Test json encoding
{
	$HashNet::StorageEngine::TransactionRecord::ENABLE_BASE64_ENCODING = 1;
	
	my $json = encode_json($tr_simple->to_hash);
	
	my $tr2 = HashNet::StorageEngine::TransactionRecord->from_hash(decode_json($json));
	is($tr2->data, $data, "JSON Encode/decode");
}


done_testing();
