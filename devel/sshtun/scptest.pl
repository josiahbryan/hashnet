use strict;
#use Net::SCP::Expect;
require 'MySCPExpect.pm';
my $scpe = Net::SCP::Expect->new;
sub getrootpw() { `cat rootpw.txt` =~ /^(.*)[\r\n]*$/;$1 }

$scpe->login('root', getrootpw());

$scpe->scp('sshtest.pl','web:~');
