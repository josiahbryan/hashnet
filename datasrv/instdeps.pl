#!/usr/bin/perl

# buildpacked.pl - Pack script and dependencies into self-extracting bash script
# Read about this script at http://www.perlmonks.org/?node_id=988804,
# or see perldocs at the end of this file.

eval 'exec /usr/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell

$VERSION = '0.80';

use warnings;
use strict;
use Config;
use Getopt::Std;
use Module::ScanDeps;
use Module::CoreList;
use ExtUtils::MakeMaker;
use Data::Dumper;
use File::Copy qw/copy/;
use File::Path qw/mkpath rmtree/; #make_path remove_tree/;
use Module::Locate qw/locate/;
use subs qw( _name );

use Data::Dumper;

my %opts;
#getopts('BVRxce:C:', \%opts);
getopts('znxcoi:C:', \%opts);

my (%map, %skip);
my $core    = 0; #$opts{B};
my $verbose = 0; #$opts{V};
#my $eval    = $opts{e};
my $recurse = 1; #$opts{R} ? 0 : 1;
my $gzip    = $opts{z};

# if ($eval) {
#     require File::Temp;
#     my ($fh, $filename) = File::Temp::tempfile( UNLINK => 1 );
#     print $fh $eval, "\n" or die $!;
#     close $fh;
#     push @ARGV, $filename;
# }

die qq{
Usage: $0 [ -x | -c ] [-C CacheFile ] [ -n ] [ -z ] [ -o OutFile ] File

  $0 scans File with Module::ScanDeps for non-core dependancies,
  copies found modules (along with the file given) into a payload tree, then
  compresses the payload into a tar archive, prepends a self-extracting
  and exeuctable header to the archive, and writes the archive to OutFile
  (also makes OutFile executable.) OutFile defaults to File with '.bin' added.

Optional Arguments:
  -o OutFile   - Write outut to OutFile instead of the default (File.bin)
  -x           - Execute code (passes 'execute => 1' to scan_deps())
  -c           - Compile code (passes 'compile => 1' to scan_deps())
  -C CacheFile - Passes CacheFile as 'cache_file => CacheFile' to scan_deps())
  -n           - Don't remove stub file/payload tar from cwd on exit
  -z           - Compress with gzip ('tar cz') instead of just 'tar c'
                 (Smaller file size at the expense of slightly longer startup)

} unless @ARGV;

my @files = @ARGV;
while (<>) {
    next unless /^package\s+([\w:]+)/;
    $skip{$1}++;
}


if(@files > 1)
{
	die "$0 only handles one file argument currently, sorry!";
}
my $input = shift @files;

# Parse the path and file from the input given

my ($input_path,$input_file) = $input =~ /(^.*\/)?([^\/]+)$/;
$input_path ||= ''; # prevent warnings of uninitalized value
$input_path =~ s/\.\///g;

# Strip ext
my $input_noext = $input_file;
$input_noext =~ s/\..*$//g;


print "$0: Scanning $input for dependencies...\n";

my $map = scan_deps(
    files   => [$input],
    recurse => $recurse,
    $opts{x} ? ( execute => 1 ) :
    $opts{c} ? ( compile => 1 ) : (),
    #$opts{V} ? ( warn_missing => 1 ) : (),
    warn_missing => 1,
    $opts{C} ? ( cache_file   => $opts{C}) : (),
);

print "$0: Processing dependencies extracted from $input...\n";

my %mods_use;
my %noncore_mod_info;

my $target_core_ver = 5.05;

# Module::CoreList was reporting 'version' was included as of 5.09, but CPAN[1] says version objects added in 5.10
# [1] http://search.cpan.org/dist/version/lib/version.pod
my %core_ver_overrides = (
	'version'	=>  5.10
);

# my %fix_dependencies = (
# 	'version'	=> 'version/vpp.pm'
# );

my @mods_to_install;

foreach my $key (sort keys %$map)
{
	my $mod  = $map->{$key};
	my $name = $mod->{name} = _name($key);
	
	print "# $key [$mod->{type}]\n" if $verbose;
	
	if ($mod->{type} eq 'shared')
	{
		$key =~ s!auto/!!;
		$key =~ s!/[^/]+$!!;
		$key =~ s!/!::!;
		$mod->{is_bin} = 1;
	}
	
	next unless $mod->{type} eq 'module';
	
	next if $skip{$name};
	
	my $module_core_ver = $core_ver_overrides{$name} || Module::CoreList->first_release($name) || -1;
	
	my $is_core = $module_core_ver      && 
	              $module_core_ver > -1 && 
	              $module_core_ver < $target_core_ver ? 1:0;
	
	#die "[$is_core] $name: $module_core_ver [target: $target_core_ver]\n" if $name eq 'version';

	if(!$is_core)
	{
		my @used_by = @{$mod->{used_by} || []};
		
		$noncore_mod_info{$mod->{key}} = $mod;
		foreach my $file_key (@used_by)
		{
			push @{$mods_use{$file_key}}, $mod->{key};
		}
	}
}

#die Dumper \%mods_use, \%noncore_mod_info;

print "$0: Finding modules to install\n";

# Add all the non-core modules referenced by the script to the payload
my @libs;
sub contains { my $x=shift; my $ref = shift; foreach my $a(@$ref){return 1 if $a eq $x; } return 0}

my %seen;
# Recursively add in dependancies
sub add_dependencies
{
	my $file_key = shift;
	
	my @noncore_deps = @{$mods_use{$file_key} || []};
	foreach my $dep_file_key (@noncore_deps)
	{
		#print "\t[debug] add_dependencies('$file_key') => '$dep_file_key'\n"; 
		if(add_module($dep_file_key, $file_key))
		{
			add_dependencies($dep_file_key);
		}
	}
	
}

sub add_module
{
	my $file_key = shift;
	
	return 0 if $seen{$file_key};
	$seen{$file_key} ++;

	my $other_key = shift; # just for output
	
	my $mod = $noncore_mod_info{$file_key} || die "Invalid file key: '$file_key'";
	my $file = $mod->{file};
	my $name = $mod->{name};
	print "$0: Adding non-core dependency '$name' (used by $other_key)\n"; #from $file\n";

	my @dyna_patterns = ('use XSLoader', 'require DynaLoader', 'use DynaLoader'); # Ignorant here, is 'use DynaLoader' ever done?
	my $dyna_count = 0;
	$dyna_count   += 0 + `grep '${_}' $file | wc -l` foreach @dyna_patterns;
	#if($mod->{is_bin}) # doesn't work, {is_bin} never set correctly
	if($dyna_count > 0)
	{
		warn "[Warn] Module '$name' looks it's not Pure-Perl - it probably won't work bundled.\n\tCheck CPAN for a pure-perl version of $name to make sure the bundled app works on all architectures";
	}

	push @mods_to_install, $name;

	return 1;
}

# Traverse the tree of dependancies, adding them to the payload
add_dependencies($input_file);

print Dumper \@mods_to_install;
# use CPAN;
# foreach my $mod (@mods_to_install)
# {
# 	print "Trying to install...\n";
# 	install($mod);
# }

sub _name {
    my $str = shift;
    $str =~ s!/!::!g;
    $str =~ s!.pm$!!i;
    $str =~ s!^auto::(.+)::.*!$1!;
    return $str;
}

1;
