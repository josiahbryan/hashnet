#!/usr/bin/perl
use common::sense;
use lib 'lib';

use HashNet::MP::GlobalDB;
use HashNet::MP::ClientHandle;
use HashNet::Util::Logging;
use File::Slurp;
#use Getopt::Std;

use Benchmark qw(:all) ;

my $db_file = 'db.gdbasic';
$HashNet::MP::LocalDB::DBFILE = ".$db_file";

HashNet::MP::LocalDB->dump_db($db_file);
HashNet::MP::GlobalDB->delete_disk_cache($db_file);

# Mute logging output
$HashNet::Util::Logging::LEVEL = 0; #-t STDIN ? 999 : 0;
$HashNet::Util::Logging::ANSI_ENABLED = 1 if $HashNet::Util::Logging::LEVEL;

my $gdb = HashNet::MP::GlobalDB->new(db_root => $db_file);

my $tests;

my $img = "hashnet-logo.png";
$img = "../$img" if !-f $img;
my $test_key = "test";
my $test_val = $$;

my %data_types = (
	data_bin => scalar(read_file($img)),
	data_ref => { $test_key => $test_val },
	data_str => 'a' x (1024 * 16),
);

#die Dumper \%data_types;

foreach my $type (keys %data_types)
{
	my $data = $data_types{$type};

	$tests->{"raw:".$type} = sub
	{
		$HashNet::MP::GlobalDB::RAW_STORE_ENABLED = 1;
		$gdb->put($type, $data);
		$gdb->get($type);
	};
	$tests->{"storable:".$type} = sub
	{
		$HashNet::MP::GlobalDB::RAW_STORE_ENABLED = 0;
		$gdb->put($type, $data);
		$gdb->get($type);
	};
}

timethese(150, $tests);

HashNet::MP::LocalDB->dump_db($db_file);
HashNet::MP::GlobalDB->delete_disk_cache($db_file);
