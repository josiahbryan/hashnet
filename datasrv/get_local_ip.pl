#!/usr/bin/perl
use strict;
use Data::Dumper;

# from http://www.perlmonks.org/?node_id=53660

my $interface;
my %IPs;

foreach ( qx{ (LC_ALL=C /sbin/ifconfig -a 2>&1) } ) 
{
        $interface = $1 if /^(\S+?):?\s/;
        next unless defined $interface;
        $IPs{$interface}->{STATE}=uc($1) if /\b(up|down)\b/i;
        $IPs{$interface}->{IP}=$1 if /inet\D+(\d+\.\d+\.\d+\.\d+)/i;
}

print Dumper(\%IPs);