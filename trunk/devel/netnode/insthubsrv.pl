#!/usr/bin/perl
use common::sense;
use lib 'lib';

use File::Slurp;
use HashNet::MP::HubServerInstaller;
use Getopt::Std;

my %opts;
getopts('f:h:u:p:o:', \%opts);

my $file = $opts{f} || undef;
my $host = $opts{h} || undef;
my $user = $opts{u} || 'root';
my $pass = $opts{p} || undef;
my $dest = $opts{o} || undef;
my $test = $opts{t} || 0;

if(@ARGV)
{
	$file = shift;
	my $host_tmp = shift;
	my @parts = split /\@/, $host_tmp;
	($user,$host) = @parts if @parts == 2;
	  $host = shift @parts if @parts == 1;
	($host, $dest) = split /:/, $host if $host =~ /:/;
}

#$dest = $file if !$dest;
die usage() if !$file || !$host;

$pass = read_file(\*STDIN) if $pass eq '-';

sub usage
{
	return "$0 [-t] [-f file] [-h host] [-u user] [-p pass] [-o outfile]\n  -or-\n$0 file user\@host:outfile\n";
}

HashNet::MP::HubServerInstaller->install(
	app_src  => $file,
	app_dest => $dest,
	host     => $host,
	user     => $user,
	pass     => $pass,
	only_testing => $test,
);