#!/usr/bin/perl

use HashNet::StorageEngine;

my $main_file = 'dengpeersrv.pl';

my $ver_file = 'HashNet/StorageEngine.pm';

my $new_ver = $HashNet::StorageEngine::VERSION + 0.0001;

system("cp $ver_file $ver_file.bak");
my $cmd = "perl -i -pe 's/our \\\$VERSION = \\d.+\\d+/our \\\$VERSION = $new_ver/' $ver_file";
#die $cmd;
system($cmd);

print "$0: Updated version to $new_ver, building $main_file now.\n";
system("perl buildpacked.pl -i favicon.ico,hashnet-logo.png,basicstyles.css -z $main_file");
print "$0: Built version $new_ver.\n";


