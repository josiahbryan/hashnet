use strict;
use warnings;
use Module::Locate qw/locate/;

my $to_find = "AnyEvent/constants.pl";

print "Perl would use: ", scalar locate($to_find), "\n";
