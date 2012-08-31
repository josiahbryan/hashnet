use strict;

my @list = `ps asx | grep inplace-upgrade-test`;

foreach my $line (@list)
{
        next if $line !~ /inplace-upgrade-test/;
	my @row = split /\s+/, $line;
        my $pid = $row[2];

        print "pid=$pid (@row)\n";
        system("kill -9 $pid");
	
}
