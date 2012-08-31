#!/usr/local/perl5.002_01/bin/perl

use strict;
use Convert::UU 'uudecode';
die "Usage: $0 file\n" unless @ARGV==1;
open F, $ARGV[0] or die "Couldn't open $ARGV[0]: $!";
#my($uudecoded_string,$file,$mode) = uudecode(\*F);


sub decode_base64 ($)
{
    local($^W) = 0; # unpack("u",...) gives bogus warning in 5.00[123]
    use integer;

    my $str = shift;
    $str =~ tr|A-Za-z0-9+=/||cd;            # remove non-base64 chars
    if (length($str) % 4) {
	require Carp;
	Carp::carp("Length of base64 data not a multiple of 4")
    }
    $str =~ s/=+$//;                        # remove padding
    $str =~ tr|A-Za-z0-9+/| -_|;            # convert to uuencoded format
    return "" unless length $str;

    ## I guess this could be written as
    #return unpack("u", join('', map( chr(32 + length($_)*3/4) . $_,
    #			$str =~ /(.{1,60})/gs) ) );
    ## but I do not like that...
    my $uustr = '';
    my ($i, $l);
    $l = length($str) - 60;
    for ($i = 0; $i <= $l; $i += 60) {
	$uustr .= "M" . substr($str, $i, 60);
    }
    $str = substr($str, $i);
    # and any leftover chars
    if ($str ne "") {
	$uustr .= chr(32 + length($str)*3/4) . $str;
    }
    return unpack ("u", $uustr);
}

<F>; # first line is header
my $uudecoded_string;
while(my $line = <F>)
{
	$uudecoded_string .= decode_base64($line); 
}

my $file = '/dev/stdout';

open F, ">$file" or die "Can't open >$file: $!";
binmode(F);
print F $uudecoded_string;
close F;
#chmod oct($mode), $file;

__END__

=head1 NAME

 puudecode - perl replacement for uudecode

=head1 SYNOPSIS

 puudecode inputfile

=head1 DESCRIPTION

Uudecode reads a uuencoded inputfile and writes the decoded string to
the file named in the uuencoded string. It changes the permissions to
the mode given in the uuencoded string.

=head1 BUGS

This implementation is much slower than most uudecode programs written
in C. Its primary intention is to allow quick testing of the
underlying Convert::UU module.

=head1 SEE ALSO

puuencode(1), Convert::UU(3)

=head1 AUTHOR

Andreas Koenig E<lt>andreas.koenig@anima.deE<gt>

=cut
