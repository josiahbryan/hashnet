#!/usr/bin/perl

use strict;

use common::sense;

use Getopt::Std;
use HashNet::Util::Logging;
use HashNet::StorageEngine;
use HashNet::StorageEngine::PeerServer;
use Cwd qw/abs_path/;
use lib 'extern';
use version::vpp; # for buildpacked.pl to pick up

print "\n$0: HashNet StorageEngine Version $HashNet::StorageEngine::VERSION\n\n";

@HashNet::StorageEngine::PeerServer::Startup_ARGV = @ARGV;


my %opts;
getopts('hkf:c:d:p:n:', \%opts);

# Get bin_file here instead of after {h} so we can print it out in the usage message
my $bin_file = abs_path($opts{f} || $0);
$bin_file =~ s/\.pl$/.bin/g;

# For debugging/status messages
my ($app_path,$app_name) = $bin_file =~ /(^.*\/)?([^\/]+)$/;


if($opts{h})
{
	my $tmp = $HashNet::StorageEngine::PEERS_CONFIG_FILE;
	my @list = ref $tmp ? @{$tmp || []} : ($tmp);
	my $file_list = join("\n                    ", @list);
	
	my $tmp2 = $HashNet::StorageEngine::PeerServer::CONFIG_FILE;
	my @list2 = ref $tmp2 ? @{$tmp2 || []} : ($tmp2);
	my $file_list2 = join("\n                    ", @list2);
	
	my $abs = abs_path($0);
	
	print qq{Usage: $0 [-h -k] [-f bin-file] [-n node-info-file] [-c peers-config-file] [-d database-path] [-p port]

  Options:
    -h       - This message
    -k       - Kill any running instances of this server and exit

    -f file  - Use 'file' as the bin file distributed to peers for upgrades
               instead of the default:
                    $bin_file

    -c file  - Use 'file' as the peers config file instead of the checking
               the default location(s):
                    $file_list

    -n file  - Use 'file' as the node info file instead of checking the
               the default location(s):
                    $file_list2

    -d path  - Use path 'path' for the database instead of the default path:
                    $HashNet::StorageEngine::DEFAULT_DB_ROOT

    -p port   - Use port 'port' for the server instead of default ($HashNet::StorageEngine::PeerServer::DEFAULT_PORT)

  Examples:

    # Run $0 with default settings
    $0

    # Kill any running instances
    $0 -k

    # Load peers from /var/lib/hashnet/peers.cfg
    $0 -c /var/lib/hashnet/peers.cfg

    # Store database in /tmp/hashnetdb instead of /var/lib/hashnet/db
    $0 -d /tmp/hashnetdb

    # Add this to crontab at a schedule of your choosing to make sure
    # $abs is always running
    pgrep -f -x $abs >/dev/null 2>/dev/null || /usr/bin/screen -L -d -m -S dengpeersrv $abs

    # Run an instance on port 8052 with configs and DB loaded from /tmp/test
    mkdir /tmp/test; $0 -c /tmp/peer.cfg -n /tmp/test/node.cfg -p 8052 -d /tmp/test/db

};
	exit 0;
}

if($opts{k})
{
	print "$0: Stopping from $$...\n";
	#my @pids = grep { $_ != $$ } split /\s/, `pidof $0`;
	my @list = `ps asx | grep $0`;
	#foreach my $pid (@pids)
	#use Data::Dumper;
	#die Dumper \@list;
	foreach my $line (@list)
	{
		next if $line !~ /$0/;
		my @row = split /\s+/, $line;
		my $pid = $row[2];
		next if $pid == $$;
		
		my @lines = split /\n/, `ps $pid`;
		shift @lines;
		if(@lines)
		{
			print STDERR "Killing $lines[0]\n";
			kill 9, $pid;
		}
	}
	exit 0;
}


# However, when the 'older' host downloads an update, its mtime will then be newer than the
# 'new' host. Then, when the new host checks against the old host, it will try to download
# the file back to the new host. And the cycle will just continue....
# So, for now, I must rely on manually incrementing the version in StorageEngine every time I
# build a new dengpeersrv.bin file.

# if(-f $bin_file)
# {
# 	my $ver = $HashNet::StorageEngine::VERSION;
# 	$ver = ("$ver" . (stat($bin_file))[9]) + 0;
# 	print "$0: Starting HashNet StorageEngine Server, version $ver\n";
# 	$HashNet::StorageEngine::VERSION = $ver;
# }

info "$app_name: Creating StorageEngine...\n";
my $con = HashNet::StorageEngine->new(
	config	=> $opts{c},
	db_root	=> $opts{d}
);

# if(-f $bin_file)
# {
# 	info "$app_name: Using bin_file to '$bin_file'\n";
# }

info "$app_name: Creating PeerServer...\n";
my $srv = HashNet::StorageEngine::PeerServer->new(
	engine   => $con,
	port     => $opts{p},
	config   => $opts{n},
	bin_file => $bin_file, 
);

info "$app_name: Running PeerServer...\n";
$srv->run;



