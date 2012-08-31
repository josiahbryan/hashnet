#!/usr/local/perl5.002_01/bin/perl

use strict;die "Usage: $0 file\n" unless @ARGV==1;open F, $ARGV[0] or die "Couldnt open $ARGV[0]: $!";sub decode_base64{local($^W) = 0;use integer;my $str = shift;$str =~ tr|A-Za-z0-9+=/||cd;$str =~ s/=+$//;$str =~ tr|A-Za-z0-9+/| -_|;return "" unless length $str;my $uustr = "";my ($i, $l);$l = length($str) - 60;for ($i = 0; $i <= $l; $i += 60) {$uustr .= "M" . substr($str, $i, 60);}$str = substr($str, $i);if ($str ne "") {$uustr .= chr(32 + length($str)*3/4) . $str;}return unpack ("u", $uustr);}<F>;my $uudecoded_string;while(my $line = <F>){$uudecoded_string .= decode_base64($line);}my $file = "/dev/stdout";open F, ">$file" or die "Cant open >$file: $!";binmode(F);print F $uudecoded_string;close F;
#chmod oct($mode), $file;
