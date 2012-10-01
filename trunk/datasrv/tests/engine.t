#!/usr/bin/perl
use strict;
use lib '..';

use Test::More;

BEGIN { use_ok('HashNet::StorageEngine'); };

use File::Path qw/rmtree/;
use Cwd qw/abs_path/;

# Make logging quiet so we can read test output more easily
use HashNet::Util::Logging;
$HashNet::Util::Logging::LEVEL = 0;

my $tmp_peer1 = "http://localhost:999/";
my $tmp_peer2 = "http://localhost:999/ http://localhost:888/";

my $engine;

{
	$engine = HashNet::StorageEngine->new(
		peer_list => [$tmp_peer1],
	);
	is($engine->{given_peers_list}->[0], $tmp_peer1, "'peer_list' arg");
	is($engine->{db_root}, $HashNet::StorageEngine::DEFAULT_DB_ROOT, "DEFAULT_DB_ROOT");
	is($engine->{tx_file}, abs_path($engine->{db_root} . $HashNet::StorageEngine::DEFAULT_DB_TXLOG), "DEFAULT_DB_TXLOG");
	
	undef $engine;
}

{
	my $tmp_invalid = '/tmp/invalid'.$$;
	my $invalid_db_root = $tmp_invalid.'/dbroot';
	my $test_config = $tmp_invalid.'/config.cfg',
	my $test_tx_file = $tmp_invalid.'/.mytx';
	
	$engine = HashNet::StorageEngine->new(
		peers_list => [$tmp_peer2],
		config	   => $test_config,
		db_root    => $invalid_db_root,
		tx_file    => $test_tx_file,
	);
	is($engine->{given_peers_list}->[0], $tmp_peer2, "'peers_list' arg");

	# This test covers both :83 and :110
	is($HashNet::StorageEngine::PEERS_CONFIG_FILE, $test_config, "'config' arg");

	is($engine->{db_root}, $invalid_db_root, "Custom db root");

	is($engine->{tx_file}, $test_tx_file, "Custom tx_file");

	rmtree($tmp_invalid);
	
	undef $engine;
}


{
	my $tmp_invalid = '/tmp/invalid'.$$;
	my $invalid_db_root = $tmp_invalid.'/dbroot';
	my $test_config = $tmp_invalid.'/config.cfg',
	my $test_tx_file = $tmp_invalid.'/.mytx';

	$engine = HashNet::StorageEngine->new(
		peers_list => [],
		config	   => $test_config,
		db_root    => $invalid_db_root,
	);
	is(scalar( @{$engine->{given_peers_list} || []} ), 0, "empty peers_list");

	isnt($engine->time_offset, 0, "time_offset!=0");

	undef $engine;

}


done_testing();
