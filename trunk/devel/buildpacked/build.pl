#!/bin/perl
use strict;
use File::Copy qw/copy/;
use File::Path qw/make_path remove_tree/;
use Data::Dumper;

my $input = shift || die "Usage: $0 <executable binary> [<output file>]\n";

# Parse the path and file from the input given
my ($input_path,$input_file) = $input =~ /(^.*\/)?([^\/]+)$/;

# Get the output from command line, if none given, guess
my $output = shift;
$output = "${input_file}p" if !$output || $output eq "";

# Make the payload folder to contain the data
my $payload_dir = "$output.bin";
system("mkdir $payload_dir") if !-d $payload_dir;

print "$0: Building payload in $payload_dir\n";

# Extract the libs used by the input
my $ldd_list = `ldd $input`;
my @real_files = $ldd_list =~ /=>\s+(\/[^\s]+)/g;

# Routine to copy a given file to the payload folder (creating the dest folder structure if it doesnt exist)
sub add_payload
{
	my $file = shift;
	my ($path,$name) = $file =~ /(^.*\/)?([^\/]+)$/;
	system("mkdir -p ${payload_dir}${path}") if ! -d "${payload_dir}${path}";
	system("cp $file ${payload_dir}${file}");
	return wantarray ? ($path,$name) : $file;
}

# Add the input executable to the payload
add_payload($input);

# Add all the .so libs referenced by the executable to the payload
my @libs;
sub contains { my $x=shift; my $ref = shift; foreach my $a(@$ref){return 1 if $a eq $x; } return 0}
foreach my $file (@real_files)
{
	my ($path,$name) = add_payload($file);
	#print "$path: $name\n";
	push @libs, $path if !contains($path, \@libs);
	#print "copy($file, \"${payload_dir}${file}\")\n";
}

# Generate the stub loader to decompress the payload
my $stub = "$output.stub";
my $tmp_dir = "/tmp";

print "$0: Writing stub loader to '$stub'\n";

# Create the lib path used in the stub
my $libs = join ':', map { s/\/$//g; "$tmp_dir/$payload_dir${_}" } @libs;

# Write the stub itself
open(STUB,">$stub") || die "Cannot write $stub";
print STUB qq{#!/bin/bash
export TMPDIR=$tmp_dir #`mktemp -d /tmp/selfextract.XXXXXX`

ARCHIVE=`awk '/^__ARCHIVE_BELOW__/ {print NR + 1; exit 0; }' \$0`

tail -n+\$ARCHIVE \$0 | tar x -C \$TMPDIR

CDIR=`pwd`
cd \$TMPDIR/${payload_dir}${input_path}
LD_LIBRARY_PATH=$libs:\$LD_LIBRARY_PATH ./$input_file \$*

cd \$CDIR
rm -rf \$TMPDIR/$payload_dir

exit 0

__ARCHIVE_BELOW__
};
close(STUB);

# Compress the payload into a single archive
my $payload_tar="$payload_dir.tar";
print "$0: Compressing $payload_dir to '$payload_tar'\n";
system("tar cf $payload_tar $payload_dir");

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
unlink($stub);
unlink($payload_tar);
remove_tree($payload_dir);

# Let the user know
print "$0: Built $output\n";
