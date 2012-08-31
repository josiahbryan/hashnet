use strict;


sub getrootpw() { `cat rootpw.txt` =~ /^(.*)[\r\n]*$/;$1 }

# use Net::SSH::Expect;
require 'MySSHExpect.pm';
require 'AnsiUtil.pl';

        #
        # You can do SSH authentication with user-password or without it.
        #

        # Making an ssh connection with user-password authentication
        # 1) construct the object
        my $ssh = Net::SSH::Expect->new (
            host => "10.10.9.6", 
            password=> getrootpw(), 
            user => 'root', 
            raw_pty => 1,
            ssh_option => '-L9965:localhost:80',
        );
        
        #$ssh->run_ssh() or die "SSH couldn't start: $!";
	
	# 2) logon to the SSH server using those credentials.
	# test the login output to make sure we had success
	my $login_output = $ssh->login();
# 	if ($login_output !~ /Welcome/) 
# 	{
# 		die "Login has failed. Login output was $login_output";
# 	}
	
        # - now you know you're logged in - #

        # disable terminal translations and echo on the SSH server
        # executing on the server the stty command:
        #$ssh->exec("stty raw -echo");

        # runs arbitrary commands and print their outputs 
        # (including the remote prompt comming at the end)
        #my $ls = $ssh->exec("ls -l /");
        #my $ls = $ssh->exec('mount | grep appcluster');
        #print($ls, "\n");
	my $ls = ssh_command($ssh, 'mount | grep appcluster');
	print $ls, "\n";

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

        print "Sleeping 999\n";
        sleep 999;
        
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
	$res = join "\n", @data;
	#print "[DEBUG] _ssh_command('$cmd'): post: $res\n";
	return $res;
}
