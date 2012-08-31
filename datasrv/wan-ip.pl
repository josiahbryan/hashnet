#!/usr/bin/perl


my $external_ip;
$external_ip = `wget -q -O - "http://checkip.dyndns.org"`;
if($external_ip =~ m/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/) {
	$external_ip = $1;
}
print("$external_ip\n");
