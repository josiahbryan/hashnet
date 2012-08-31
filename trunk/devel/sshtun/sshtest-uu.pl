use strict;

sub getrootpw() { `cat rootpw.txt` =~ /^(.*)[\r\n]*$/;$1 }

# use Net::SSH::Expect;
require 'MySSHExpect.pm';
require 'AnsiUtil.pl';

	my $ssh = Net::SSH::Expect->new (
		host => "10.10.9.6", 
		password=> getrootpw(), 
		user => 'root', 
		raw_pty => 1,
		#ssh_option => '-L9965:localhost:80',
	);
	
	my $login_output = $ssh->login();
	
	#my $ls = ssh_command($ssh, 'mount | grep appcluster');
	#print $ls, "\n";
	
	my $file = 'AnsiUtil.pl';
	
	my $stat = (stat $file)[2] or die "Couln't stat $file: $!";
	my($mode) = sprintf "%04o", $stat & 07777;

	my $pid = open(README, "uuencode -m $file /dev/stdout |")  or die "Couldn't fork: $!\n";
	my @buffer;
	my $tmpfile = '~/test.dat';
	while (<README>) {
		s/[\r\n]+$//g;
		my $cmd = "echo $_ >> $tmpfile";
		print "[$cmd]\n";
		push @buffer, $cmd;
		
	}
	
	# This routine here is a oneliner to brute force decode the base64-encoded data.
	# The core sub, decode_base64, was taken from MIME::Base64::Perl wholesale and stripped of whitespace/comments and edited to work in a single line
	my $uudecode_perl = 'use strict;open F, $ARGV[0] or die "Couldnt open $ARGV[0]: $!";sub decode_base64{local($^W) = 0;use integer;my $str = shift;$str =~ tr|A-Za-z0-9+=/||cd;$str =~ s/=+$//;$str =~ tr|A-Za-z0-9+/| -_|;return "" unless length $str;my $uustr = "";my ($i, $l);$l = length($str) - 60;for ($i = 0; $i <= $l; $i += 60) {$uustr .= "M" . substr($str, $i, 60);}$str = substr($str, $i);if ($str ne "") {$uustr .= chr(32 + length($str)*3/4) . $str;}return unpack ("u", $uustr);}<F>;my $uudecoded_string;while(my $line = <F>){$uudecoded_string .= decode_base64($line);}my $file = "/dev/stdout";open F, ">$file" or die "Cant open >$file: $!";binmode(F);print F $uudecoded_string;close F;chmod oct($ARGV[1]), $file if @ARGV[1];unlink $ARGV[0]';
	
	my $cmd = "perl -e '$uudecode_perl' $tmpfile $mode > $file";
	push @buffer, $cmd;
# 	print "Executing uudecode: '$cmd'\n";
# 	my $out = $ssh->exec($cmd);
# 	print "Done exec\n";
# 	print "out:[$out]\n";
	
# 	print "Executing buffer\n";
# 	my $out = $ssh->exec(join(';', @buffer));
# 	print "Done exec\n";
# 	print "out:[$out]\n";

	print "Executing buffer\n";
	my $out = ssh_command($ssh, join(';', @buffer));
	print "Done exec\n";
	print "out:[$out]\n";


	close(README)                               or die "Couldn't close: $!\n";
	
# 	# This routine here is a oneliner to brute force decode the base64-encoded data.
# 	# The core sub, decode_base64, was taken from MIME::Base64::Perl wholesale and stripped of whitespace/comments and edited to work in a single line
# 	my $uudecode_perl = 'use strict;open F, $ARGV[0] or die "Couldnt open $ARGV[0]: $!";sub decode_base64{local($^W) = 0;use integer;my $str = shift;$str =~ tr|A-Za-z0-9+=/||cd;$str =~ s/=+$//;$str =~ tr|A-Za-z0-9+/| -_|;return "" unless length $str;my $uustr = "";my ($i, $l);$l = length($str) - 60;for ($i = 0; $i <= $l; $i += 60) {$uustr .= "M" . substr($str, $i, 60);}$str = substr($str, $i);if ($str ne "") {$uustr .= chr(32 + length($str)*3/4) . $str;}return unpack ("u", $uustr);}<F>;my $uudecoded_string;while(my $line = <F>){$uudecoded_string .= decode_base64($line);}my $file = "/dev/stdout";open F, ">$file" or die "Cant open >$file: $!";binmode(F);print F $uudecoded_string;close F;chmod oct($ARGV[1]), $file if @ARGV[1]';
# 	
# 	my $cmd = "perl -e '$uudecode_perl' $tmpfile $mode > $file";
# 	print "Executing uudecode: '$cmd'\n";
# 	my $out = $ssh->exec($cmd);
# 	print "Done exec\n";
# 	print "out:[$out]\n";


	#print "Sleeping 999\n";
	#sleep 999;
	
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
