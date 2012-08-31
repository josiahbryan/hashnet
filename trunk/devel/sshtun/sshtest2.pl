use strict;

require 'AnsiTrim.pl';
#use Net::SSH::Expect;
require 'MyNetSSHExpect.pm'; # patched to handle no-password-needed situations

sub getrootpw() { `cat rootpw.txt` =~ /^(.*)[\r\n]*$/;$1 }

my $ssh = Net::SSH::Expect->new (
	#host => "192.168.0.2",
	#host => 'productiveconcepts.com',
	host => 'bryannet.na.tl',
	password => getrootpw(),
	user => 'root',
	raw_pty => 1,
	ssh_option => '-R 8022:localhost:22'

);

# 2) logon to the SSH server using those credentials.
# test the login output to make sure we had success
my $login_output = $ssh->login();

# disable terminal translations and echo on the SSH server
# executing on the server the stty command:
#        $ssh->exec("stty raw -echo");

# runs arbitrary commands and print their outputs
# (including the remote prompt comming at the end)
my $ls = ssh_command($ssh, "ifconfig eth0 ; uname -a");
#my $ls = $ssh->exec('mount | grep appcluster');
print($ls);
        
#my $who = $ssh->exec("who");
#print ($who);


#         # Now let's run an interactive command, like passwd.
#         # This is done combining send() and waitfor() methods together:
#         $ssh->send("passwd");
#         $ssh->waitfor('password:\s*\z', 1) or die "prompt 'password' not found after 1 second";
#         $ssh->send("curren_password");
#         $ssh->waitfor(':\s*\z', 1) or die "prompt 'New password:' not found";
#         $ssh->send("new_password");
#         $ssh->waitfor(':\s*\z', 1) or die "prompt 'Confirm new password:' not found";
#         $ssh->send("new_password");


# closes the ssh connection
$ssh->close();

sub ssh_command
{
	my $con = shift;
	#my $self = shift;
	my $cmd = shift;
	#my $con = $self->ssh_connection;
	my $res = trim_ansi_codes($con->exec($cmd));
	$res =~ s/\r//g;
	#print "[DEBUG] _ssh_command('$cmd'):  pre: $res\n";
	my @data = split /\n/, $res;
	shift @data if index($data[0],substr($cmd,0,32))>-1; #first line echos $cmd
	pop @data; #last line has cmd prompt
	$res = join("\n", @data). "\n";
	#print "[DEBUG] _ssh_command('$cmd'): post: $res\n";
	return $res;
}
