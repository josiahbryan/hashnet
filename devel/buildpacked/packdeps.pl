#!/usr/bin/perl

eval 'exec /usr/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell

$VERSION = '0.76';

use strict;
use Config;
use Getopt::Std;
use Module::ScanDeps;
use ExtUtils::MakeMaker;
use Data::Dumper;
use Pod::Strip;
use subs qw( _name _modtree );

my %opts;
getopts('BVRxce:C:', \%opts);

my (%map, %skip);
my $core    = $opts{B};
my $verbose = $opts{V};
my $eval    = $opts{e};
my $recurse = $opts{R} ? 0 : 1;

if ($eval) {
    require File::Temp;
    my ($fh, $filename) = File::Temp::tempfile( UNLINK => 1 );
    print $fh $eval, "\n" or die $!;
    close $fh;
    push @ARGV, $filename;
}

die "Usage: $0 [ -B ] [ -V ] [ -x | -c ] [ -R ] [-C FILE ] [ -e STRING | FILE ... ]\n" unless @ARGV;

my @files = @ARGV;
while (<>) {
    next unless /^package\s+([\w:]+)/;
    $skip{$1}++;
}

my $map = scan_deps(
    files   => \@files,
    recurse => $recurse,
    $opts{x} ? ( execute => 1 ) :
    $opts{c} ? ( compile => 1 ) : (),
    $opts{V} ? ( warn_missing => 1 ) : (),
    $opts{C} ? ( cache_file   => $opts{C}) : (),
);


my $len = 0;
my @todo;
my (%seen, %dist, %core, %bin);

my %noncore_dep;

foreach my $key (sort keys %$map) {
    my $mod  = $map->{$key};
    my $name = $mod->{name} = _name($key);

    print "# $key [$mod->{type}]\n" if $verbose;

    if ($mod->{type} eq 'shared') {
        $key =~ s!auto/!!;
        $key =~ s!/[^/]+$!!;
        $key =~ s!/!::!;
        $bin{$key}++;
    }

    next unless $mod->{type} eq 'module';

    next if $skip{$name};

    my $privPath = "$Config::Config{privlibexp}/$key";
    my $archPath = "$Config::Config{archlibexp}/$key";
    $privPath =~ s|\\|\/|og;
    $archPath =~ s|\\|\/|og;
    if ($mod->{file} eq $privPath
        or $mod->{file} eq $archPath) {
        next unless $core;

        $core{$name}++;
    }
    elsif (my $dist = _modtree->{$name}) {
	#print "Mod file: $mod->{file}\n";
	$noncore_dep{$name} = $mod;
        $seen{$name} = $dist{$dist->package}++;
    }

    $len = length($name) if $len < length($name);
    $mod->{used_by} ||= [];

    push @todo, $mod;
}

$len += 2;

# print "# Legend: [C]ore [X]ternal [S]ubmodule [?]NotOnCPAN\n" if $verbose;
# 
# foreach my $mod (sort {
#     "@{$a->{used_by}}" cmp "@{$b->{used_by}}" or
#     $a->{key} cmp $b->{key}
# } @todo) {
# 
#     my $version = MM->parse_version($mod->{file});
# 
#     if (!$verbose) {
#         printf "%-${len}s => '$version',", "'$mod->{name}'" if $version;
#     } else {
#         printf "%-${len}s => '0', # ", "'$mod->{name}'";
#         my @base = map(_name($_), @{$mod->{used_by}});
#         print $seen{$mod->{name}} ? 'S' : ' ';
#         print $bin{$mod->{name}}  ? 'X' : ' ';
#         print $core{$mod->{name}} ? 'C' : ' ';
#         print _modtree && !_modtree->{$mod->{name}} ? '?' : ' ';
#         print " # ";
#         print "@base" if @base;
#     }
#     print "\n";
# 
# }
# 
# warn "No modules found!\n" unless @todo;

#unlink("a.pl") if -f 'a.pl';
open(OUT, ">a.pl") || die "Cannot write a.pl: $!";


foreach my $name (keys %noncore_dep)
{
	my $mod = $noncore_dep{$name};
	my $file = $mod->{file};
	print "noncore_dep: $name ($file)\n";
	#print Dumper $mod;
	#system("cat $mod->{file} >> a.pl");
	my $buffer = `cat $file`;
	foreach my $name (keys %noncore_dep)
	{
		#print "Replacing $name in $file...\n";
		my $mod = $noncore_dep{$name};
		$buffer =~ s/use $name;/# use $name;\t # Packaged above from original source at $mod->{file}/g;
	}
	my $pod_strip = Pod::Strip->new;
	my $podless;
	$pod_strip->output_string(\$podless);
	$pod_strip->parse_string_document($buffer);
	$podless =~ s/__DATA__.*$//sgi;
	print OUT $podless;
}

foreach my $file (@files)
{
	#system("cat $file >> a.pl");
	my $buffer = `cat $file`;
	foreach my $name (keys %noncore_dep)
	{
		#print "Replacing $name in $file...\n";
		my $mod = $noncore_dep{$name};
		$buffer =~ s/use $name;/# use $name;\t # Packaged above from original source at $mod->{file}/g;
	}
	print OUT $buffer;
}
close(OUT);

print "Wrote a.pl\n";


sub _name {
    my $str = shift;
    $str =~ s!/!::!g;
    $str =~ s!.pm$!!i;
    $str =~ s!^auto::(.+)::.*!$1!;
    return $str;
}

my $modtree;
sub _modtree {
    $modtree ||= eval {
        require CPANPLUS::Backend;
        CPANPLUS::Backend->new->module_tree;
    } || {};
}


1;

__END__

=head1 NAME

scandeps.pl - Scan file prerequisites

=head1 SYNOPSIS

    % scandeps.pl *.pm          # Print PREREQ_PM section for *.pm
    % scandeps.pl -e 'STRING'	# Scan an one-liner
    % scandeps.pl -B *.pm       # Include core modules
    % scandeps.pl -V *.pm       # Show autoload/shared/data files
    % scandeps.pl -R *.pm       # Don't recurse
    % scandeps.pl -C CACHEFILE  # use CACHEFILE to cache dependencies

=head1 DESCRIPTION

F<scandeps.pl> is a simple-minded utility that prints out the
C<PREREQ_PM> section needed by modules.

If you have B<CPANPLUS> installed, modules that are part of an
earlier module's distribution with be denoted with C<S>; modules
without a distribution name on CPAN are marked with C<?>.

Also, if the C<-B> option is specified, module belongs to a perl
distribution on CPAN (and thus uninstallable by C<CPAN.pm> or
C<CPANPLUS.pm>) are marked with C<C>.

Finally, modules that has loadable shared object files (usually
needing a compiler to install) are marked with C<X>; with the
C<-V> flag, those files (and all other files found) will be listed
before the main output. Additionally, all module files that the
scanned code depends on but were not found (and thus not scanned
recursively) are listed. These may include genuinely missing
modules or false positives. That means, modules your code does
not depend on (on this particular platform) but that were picked
up by the heuristic anyway.

=head1 OPTIONS

=over 4

=item -e STRING

Scan I<STRING> as a string containing perl code.

=item -c

Compiles the code and inspects its C<%INC>, in addition to static scanning.

=item -x

Executes the code and inspects its C<%INC>, in addition to static scanning.

=item -B

Include core modules in the output and the recursive search list.

=item -R

Only show dependencies found in the files listed and do not recurse.

=item -V

Verbose mode: Output all files found during the process; 
show dependencies between modules and availability.

Additionally, warns of any missing dependencies. If you find missing
dependencies that aren't really dependencies, you have probably found
false positives.

=item -C CACHEFILE

Use CACHEFILE to speed up the scanning process by caching dependencies.
Creates CACHEFILE if it does not exist yet.

=back

=head1 SEE ALSO

L<Module::ScanDeps>, L<CPANPLUS::Backend>, L<PAR>

=head1 ACKNOWLEDGMENTS

Simon Cozens, for suggesting this script to be written.

=head1 AUTHORS

Audrey Tang E<lt>autrijus@autrijus.orgE<gt>

=head1 COPYRIGHT

Copyright 2003, 2004, 2005, 2006 by Audrey Tang E<lt>autrijus@autrijus.orgE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut
