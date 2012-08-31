use strict;

use Module::ScanDeps;

use Data::Dumper;

# # App::Packer::Frontend compatible interface
# # see App::Packer::Frontend for the structure returned by get_files
# my $scan = Module::ScanDeps->new;
# $scan->set_file( 'datasrv.pl' );
# #$scan->set_options( add_modules => [ 'Test::More' ] );
# $scan->calculate_info;
# my $files = $scan->get_files;
# 
# print Dumper $files;


# standard usage
my $hash_ref = scan_deps(
	files   => [ 'datasrv.pl' ],
	recurse => 1,
);

# shorthand; assume recurse == 1
#my $hash_ref = scan_deps( 'a.pl', 'b.pl' );

print Dumper $hash_ref;