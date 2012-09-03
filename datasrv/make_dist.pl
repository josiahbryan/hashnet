#!/usr/bin/perl

use common::sense;
use HashNet::StorageEngine;


my $up_ver = 1;

my $main_file = 'dengpeersrv.pl';

my $new_ver;
if($up_ver)
{

	my $ver_file = 'HashNet/StorageEngine.pm';

	$new_ver = $HashNet::StorageEngine::VERSION + 0.0001;

	system("cp $ver_file $ver_file.bak");
	my $cmd = "perl -i -pe 's/our \\\$VERSION = \\d.+\\d+/our \\\$VERSION = $new_ver/' $ver_file";
	#die $cmd;
	system($cmd);

	print "$0: Updated version to $new_ver, building $main_file now.\n";
}
else
{
	$new_ver = $HashNet::StorageEngine::VERSION;
	print "$0: Version number NOT changed, just building $main_file\n";
}

system("perl buildpacked.pl -i favicon.ico,hashnet-logo.png,basicstyles.css -z $main_file");

print "$0: Built version $new_ver.\n";


