#!/usr/bin/perl
use common::sense;
use lib 'lib';

use HashNet::MP::GlobalDB;
use HashNet::MP::ClientHandle;
use HashNet::Util::Logging;

my $key = @ARGV ? shift @ARGV : 'test';
my $logging = @ARGV ? shift @ARGV : 0;
$logging = 99 if $logging;

my $ch  = HashNet::MP::ClientHandle->setup(log_level => $logging);
#my $ch  = HashNet::MP::ClientHandle->setup();
my $eng = HashNet::MP::GlobalDB->new($ch);

#trace "$0: Waiting a second for any messages to come in\n";
$ch->wait_for_receive(msgs => 1, timeout => 1, speed => 1);

trace "$0: Gettting $key\n";
my %data = $eng->get($key);
if(!scalar(keys %data))
{
	trace "$0: Key '$key' not found in the database\n";
	warn "Error: Value for '$key' not found in the database.\n";
	exit(-1);
}

#trace "$0: Got '$key': ".Dumper(\%data);

trace "$0: Got '$key' => ".$eng->printable_value($data{data})."\n";

if(-t STDOUT)
{
	if($eng->is_printable($data{data}))
	{
		print $data{data}, "\n";
	}
	else
	{
		print $eng->printable_value($data{data}), "\n# Recirect with \"$0 $key > somefile\" to get raw binary data\n";
	}
}
else
{
	print $data{data};
}

trace "$0: Done\n";

exit;