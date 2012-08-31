#!/usr/bin/perl
use strict;

use Data::Dumper;
my $QRC_COUNTER = 0;

my $exe = shift || die "Usage: $0 <executable binary> [<output file>]\n";

my $output = shift;
if(!$output || $output eq "")
{
	($output) = $exe =~ /.*?\/?([^\/]+)$/;
	$output .= 'p';
}

my $ldd_list = `ldd $exe`;

my @real_files = $ldd_list =~ /=>\s+(\/[^\s]+)/g;

open(PRI_FILE,   ">input.pri")  || die "Cannot write to input.pri: $!";
print PRI_FILE   "TARGET=${output}\n";

open(INDEX_FILE, ">FileIndex.cpp") || die "Cannot write to index.list: $!";
print INDEX_FILE "static QStringList FileIndex = QStringList()\n\t<< \"$exe\"\n";

output_qrc($exe);

foreach my $file (@real_files)
{
	output_qrc($file);
	print INDEX_FILE "\t<< \"$file\"\n";
}
output_qrc('index.list');

print INDEX_FILE ";\n";

close(PRI_FILE);
close(INDEX_FILE);

#system('make');

#die Dumper \@real_files;

sub output_qrc
{
	$QRC_COUNTER ++ ;
	
	my $file = shift;
	my $qrc = "input-$QRC_COUNTER.qrc";
	open(QRC_FILE, ">$qrc") || die "Cannot write to $qrc: $!";
	print QRC_FILE "<!DOCTYPE RCC><RCC version=\"1.0\">\n<qresource prefix='ext'>\n";
	print QRC_FILE "\t<file>$file</file>\n";
	print QRC_FILE "</qresource>\n</RCC>\n";
	close(QRC_FILE);
	print PRI_FILE "RESOURCES += $qrc\n";
}
