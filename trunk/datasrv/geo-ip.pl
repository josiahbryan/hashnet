#!/usr/bin/perl
# IP geolocation by nwo.
#
# the first database is frighteningly accurate when it locates an IP.
# it was off by approximately 2 blocks from my house when I looked up mine.
#
# 10/26/2007

use Socket;

sub resolv {
  local($host) = @_;
  $address = inet_ntoa(inet_aton($host));
  return($address);
}

$ip = $ARGV[0];

if($ip =~ /\w+/) {
  $host = $ip;
  $ip = &resolv($ip);
}

#  use Geo::IP;
# my $gi = Geo::IP->new(GEOIP_MEMORY_CACHE);
# # look up IP address '24.24.24.24'
# # returns undef if country is unallocated, or not defined in our database
# my $country = $gi->country_code_by_addr('24.24.24.24');
# $country = $gi->country_code_by_name('yahoo.com');
# # $country is equal to "US"
# print "Country: $country\n";

use Geo::IP;
my $gi = Geo::IP->open("/usr/local/share/GeoIP/GeoLiteCity.dat", GEOIP_STANDARD);
my $record = $gi->record_by_addr($ip); #'24.24.24.24');
print join (", ", 
	$record->country_code,
	$record->country_code3,
	$record->country_name,
	$record->region,
	$record->region_name,
	$record->city,
	$record->postal_code,
	$record->latitude,
	$record->longitude,
	$record->time_zone,
	$record->area_code,
	$record->continent_code,
	$record->metro_code), "\n";




exit 0;


my $url = "http://api.hostip.info/get_html.php?ip=$ip";
print "Looking up $ip at $url\n";

open(F, "wget -q -O - $url\|") || die "$!";
while() {

  if(/^Country:\s+(.*)/) {
    $country = $1;
    next;
  }

  if(/^City:\s+(.*)/) {
    $city = $1;
    next;
  }
}
print "\n\n";
print "+-- Detailed location attempt --+\n";
print "Information for: $ip ($host)\n";
print "Best guess: $city - $country\n";
print "\n\n";
close(F);

open(F, "wget -q -O - http://netgeo.caida.org/perl/netgeo.cgi?target=$ip|") || die "$!";
while() {
  if(/^.*?CITY:\s+(.*)/) {
    $city = $1;
    if($city eq "") { $city = "unknown"; }
    next;
  }
  if(/^.*?STATE:\s+(.*)/) {
    $state = $1;
    if($state eq "") { $state = "unknown"; }
    next;
  }
  if(/^.*?COUNTRY:\s+(.*)/) {
    $country = $1;
    if($country eq "") { $country = "unknown"; }
    next;
  }
  if(/^.*?DOMAIN_GUESS:\s+(.*)/) {
    $domain = $1;
    if($domain eq "") { $domain = "unknown"; }
    next;
  }
}
print "+-- Guessed location. --+\n";
print "Location: $city, $state - $country\n";
print "Domain: $domain\n";
print "\n\n";