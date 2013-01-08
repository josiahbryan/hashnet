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

# Get the output from command line, if none given, guess
my $output = $opts{o} || '';
$output = "${input_noext}.bin" if !$output || $output eq "";

my $output_noext = $input_noext;

# Make the payload folder to contain the data
my $payload_dir = "$output_noext.files";
if(-d $payload_dir)
{
	warn "[Warn] '$payload_dir' payload folder exists, remove to ensure a clean payload.";
}
mkdir($payload_dir) if !-d $payload_dir;


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

print "$0: Building payload in $payload_dir\n";

# Routine to copy a given file to the payload folder (creating the dest folder structure if it doesnt exist)
sub add_payload
{
	my $file = shift;
	
	my $out_file = $file;
	$out_file = '/'.$file if $file !~ /^\//;
	
	my ($path,$name) = $out_file =~ /(^.*\/)?([^\/]+)$/;

	$path ||= ''; # prevent warnings of uninitalized value
	my $payload_path = $payload_dir.$path;

	#system("mkdir -p ${payload_dir}${path}") if ! -d "${payload_dir}${path}";
	#make_path($payload_path) if !-d $payload_path;
	mkpath($payload_path) if !-d $payload_path;

	#system("cp $file ${payload_dir}${out_file}");
	#print STDERR "Debug: Copying '$file' -> '$payload_dir.$out_file' ($payload_path)\n";;
	copy($file, $payload_dir.$out_file);

	return wantarray ? ($path,$name) : $file;
}

# Add the input executable to the payload
add_payload($input);

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

	if($file_key eq 'AnyEvent.pm')
	{
		# For some reason, scan_deps() doesn't pick this up
		add_payload(scalar locate('AnyEvent/constants.pl'));
	}
	
	if($file_key eq 'version.pm')
	{
		# Causes odd version::vxs errors if we package this in the file
		print "$0: NOT adding version.pm\n";
		return 0;
	}
	
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

	my ($file_path,$file_name) = add_payload($file);
	#print "$path: $name\n";

	my @lib_path = split /\//, $file_path;
	my @mod_path = split /::/, $name;
	pop @mod_path; # last element of mod is the module itself, e.x. Test::Bar would equal Test/Bar.pm - we just want the folder path, not the file

	# Assuming lib_path is [usr,lib,perl5,HTML,Server] and mod_path is [HTML,Server],
	# then we want to pop off the end elements till we reach the 'perl5' element in lib_path
	# (the element where they both differ.) Then we throw perl5 back on the end of lib_path
	# and use that as the root of the library tree

	# This construct causes warnings of uninitalized values
	#my $tmp = 0;
	#1 while pop @mod_path eq ($tmp = pop @lib_path);
	#push @lib_path, $tmp;

	my $done = 0;
	while(!$done)
	{
		my $p1 = pop @mod_path || '';
		my $p2 = pop @lib_path || '';
		if($p1 ne $p2)
		{
			$done = 1;
			push @lib_path, $p2;
		}
	}

	my $lib_path = join('/', @lib_path);
	
	push @libs, $lib_path if !contains($lib_path, \@libs);
	#print "copy($file, \"${payload_dir}${file}\")\n";
	#print Dumper $mod;
	
	return 1;
}

# Traverse the tree of dependancies, adding them to the payload
add_dependencies($input_file);

# Add any forced included files
if($opts{i})
{
	my @force_incs = split /,/, $opts{i};
	foreach my $inc (@force_incs)
	{
		print STDERR "$0: Adding $inc to payload...\n";
		add_payload($inc);
	}
}

# Generate the stub loader to decompress the payload
my $stub = "$output_noext.stub";
my $tmp_dir = "/tmp";

print "$0: Writing stub loader to '$stub'\n";

# Create the lib path used in the stub
my $libs = join " \\\n\t", map { s/\/$//g; "-Mlib='$tmp_dir/$payload_dir${_}'" } @libs;
$libs = " \\\n\t$libs \\\n\t" if @libs;

my $zflag = $gzip ? 'z' : '';

# Write the stub itself
open(STUB,">$stub") || die "Cannot write $stub";
print STUB qq{#!/bin/bash
# Set the extraction location
export TMPDIR=$tmp_dir #`mktemp -d /tmp/selfextract.XXXXXX`

# Find the line on which the payload starts
ARCHIVE=`awk '/^__ARCHIVE_BELOW__/ {print NR + 1; exit 0; }' \$0`

# Extract the payload to our folder
tail -n+\$ARCHIVE \$0 | tar ${zflag}x -C \$TMPDIR

# If they just want to extract, then quit (used like this: UNTAR_ONLY=true ./outputfile.bin)
if [ "\${UNTAR_ONLY}" = "true" ]; then
	echo Only extracting, not runing. Exiting.
	exit 0
fi

RESTART_REQUESTED=false
DONE=0;
while [ \$DONE -lt 1 ]; do
	DONE=1
	
	# Set the library path and executable name for perl then jump the the entry point script
	SCRIPT_FILE=\$TMPDIR/${payload_dir}${input_path}/$input_file \\
	PACKED_ROOT=\$TMPDIR/${payload_dir}/ \\
	perl $libs -e "shift \@ARGV; \\\$0='\$0'; do '\$TMPDIR/${payload_dir}${input_path}/$input_file'; die \\\$@ if \\\$@" - \$*
	# The '-' before \$* is necessary to keep the perl interpreter from interpreting any switches passed in \$*
	# Without the '-', perl grabs things like -h and prints the help for the perl binary - $input_file never
	# sees the switch. With the extra '-' there, perl ignores the args \$*. We then shift the '-' off the \@ARGV
	# list before calling $input_file so the packed script is none the wiser.
	
	# Attempt to restart if requested (e.g. the app set \$ENV{RESTART_REQUESTED}='true'
	if [ "\${RESTART_REQUESTED}" = "true" ]; then
		
		echo $0: Restarting $input_file
		
		# Disable the done flag, causing the while loop to 'loop' again
		DONE=0
		
		# Reset the flag
		RESTART_REQUESTED=false
	fi
done

if [ "\${NO_CLEANUP}" = "true" ]; then
	echo Not removing \$TMPDIR/$payload_dir because NO_CLEANUP is 'true';
	exit 0
fi

# Cleanup and exit
rm -rf \$TMPDIR/$payload_dir
exit 0

__ARCHIVE_BELOW__
};
close(STUB);

# Compress the payload into a single archive
my $payload_tar="$payload_dir.tar";
print "$0: Compressing $payload_dir to '$payload_tar'\n";
system("tar ${zflag}cf $payload_tar $payload_dir");

# Combine the stub and the payload archive into a single executable
if(-f $payload_tar)
{
	system("cat $stub $payload_tar > $output");
	system("chmod +x $output");
}
else
{
	print STDERR "$payload_tar does not exist\n";
	exit(1);
}

# Cleanup
unless($opts{n})
{
	print "$0: Cleaning up $stub\n";
	unlink($stub);
	print "$0: Cleaning up $payload_dir\n";
	unlink($payload_tar);
}
print "$0: Removing temporary payload tree '$payload_dir'\n";
#remove_tree($payload_dir);
rmtree($payload_dir);

# Let the user know
print "$0: Built $output\n";

sub _name {
    my $str = shift;
    $str =~ s!/!::!g;
    $str =~ s!.pm$!!i;
    $str =~ s!^auto::(.+)::.*!$1!;
    return $str;
}

1;

__END__

=head1 NAME

buildpacked.pl - Build a packed bash script containing a given file and it's non-core prerequisites

=head1 SYNOPSIS

    % buildpacked.pl test.pl         # Build 'test.bin' from test.pl & dependencies
    % buildpacked.pl -o test test.pl # Build 'test' from test.pl
    % buildpacked.pl -n test.pl      # Build 'test.bin', don't remove test.stub or test.files.tar

=head1 DESCRIPTION

F<buildpacked.pl> is a derivative of the F<scandeps.pl> utility
included with C<Module::ScanDepps>. Instead of printing out the
prerequisites needed by the given file, F<buildpacked.pl> creates
a self-extracting Bash script with the prereqs and the file given
that can be distributed to other computers that may lack the
non-core prerequisites required.

Modules that has loadable shared object files (usually
needing a compiler to install) are included, however a warning is
printed. Note that this script is not smart enough (yet) to include
the shared object files - so likely the resulting file will fail
to execute on systems without the module already installed. Your
best bet is to find a pure-perl version of the warned module and
change your code to use that instead - that is, if your goal is
to create a purely portable file.

=head1 NOTE

This is NOT intended to be a replacement for PAR::Packer, pp, or
any of it's ilk. This really just handles a small nitch case,
and its a much dumber set of routines than PAR::Packer/pp.

The primary use case that I created this script to cover is
to create a cross-platform (64bit/32bit) file that only includes
non-core modules which will run on systems that already have
some 'recent' version of Perl.

I ran into problems trying to create a single-file perl script
with pp that crossed platforms (32bit to 64bit or vis a versa)
which no amount of googling solved. (Mainly having to do with
DynaLoader code calls even though I only depended on Pure Perl
modules in my code.)

In summary, this script works for pure-perl non-core dependancies
on systems with perl already installed. It's not a replacement
for pp, rather a small nitch script that may or may not work
better for very small nitch cases.

=head1 OPTIONS

=over 4

=item -o OUTPUT_FILE

Write the output to I<OUTPUT_FILE> instead of the default
(input file name with '.bin' appended)

=item -c

Compiles the code and inspects its C<%INC>, in addition to static scanning.

=item -x

Executes the code and inspects its C<%INC>, in addition to static scanning.

=item -n

Don't clean up the stub or tar archive created before exiting.

=item -C CACHEFILE

Use CACHEFILE to speed up the scanning process by caching dependencies.
Creates CACHEFILE if it does not exist yet.

=back

=head1 SEE ALSO

L<Module::ScanDeps>, L<CPANPLUS::Backend>, L<PAR>, L<PAR::Packer>

=head1 AUTHORS

Josiah Bryan E<lt>josiahbryan@gmail.comE<gt> - Added archive and stub file creation

Audrey Tang E<lt>autrijus@autrijus.orgE<gt> - Original scandeps.pl script

=head1 COPYRIGHT

Copyright 2012 by Josiah Bryan E<lt>josiahbryan@gmail.comE<gt>

Original scandeps.pl script:
Copyright 2003, 2004, 2005, 2006 by Audrey Tang E<lt>autrijus@autrijus.orgE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut
