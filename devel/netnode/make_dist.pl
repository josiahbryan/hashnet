#!/usr/bin/perl

use common::sense;
use lib 'lib';
use HashNet::MP::MessageHub; # to get $VERSION
#use HashNet::StorageEngine::PeerServer; # to get %HTTP_FILE_RESOURCES
use Cwd qw/abs_path/; # for @inc_list

my $up_ver = 1;

my $main_file = 'hubserver.pl';

my $new_ver;
if($up_ver)
{

	my $ver_file = 'lib/HashNet/MP/MessageHub.pm';

	$new_ver = $HashNet::MP::MessageHub::VERSION + 0.0001;

	system("cp $ver_file $ver_file.bak");
	my $cmd = "perl -i -pe 's/our \\\$VERSION = \\d.+\\d+/our \\\$VERSION = $new_ver/' $ver_file";
	#die $cmd;
	system($cmd);

	print "$0: Updated version to $new_ver, building $main_file now.\n";
}
else
{
	$new_ver = $HashNet::MP::MessageHub::VERSION;
	print "$0: Version number NOT changed, just building $main_file\n";
}

my @inc_list;

# use Module::Locate qw/locate/;
# # Core mod I think - it doesn't get packaged, and we need the newest version, so package it here anyway
# my $ping_mod = locate("Net::Ping");
# 
# @inc_list = ($ping_mod);
# 
# my %http_res = %HashNet::StorageEngine::PeerServer::HTTP_FILE_RESOURCES;
# foreach my $key (keys %http_res)
# {
# 	push @inc_list, ($http_res{$key});
# }
my $extra_includes = join ',', @inc_list;

system("perl buildpacked.pl ".($extra_includes ? "-i $extra_includes ":" ")." -z $main_file");

print "$0: Built version $new_ver.\n";



