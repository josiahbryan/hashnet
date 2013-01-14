use strict;

sub getrootpw() { `cat rootpw.txt` =~ /^(.*)[\r\n]*$/;$1 }

# use Net::SSH::Expect;
require 'MySSHExpect.pm';
require 'AnsiUtil.pl';

use Data::Dumper;
use MIME::Base64::Perl;
use File::Slurp;
use Getopt::Std;

my %opts;
getopts('f:h:u:p:o:', \%opts);

my $file = $opts{f} || undef;
my $host = $opts{h} || undef;
my $user = $opts{u} || 'root';
my $pass = $opts{p} || undef;
my $dest = $opts{o} || undef;

if(@ARGV)
{
	$file = shift;
	my $host_tmp = shift;
	#$host_tmp =~ /^(?:(.*?)@)(.*+)(?:\:(.*?))?/;
	my @parts = split /\@/, $host_tmp;
	($user,$host) = @parts if @parts == 2;
	$host = shift @parts if @parts == 1;
	($host, $dest) = split /:/, $host if $host =~ /:/;

	#print Dumper($file,$user,$host,$dest);
}

$dest = $file if !$dest;
die usage() if !$file || !$host;

$pass = read_file(\*STDIN) if $pass eq '-';

sub usage
{
	return "$0 [-f file] [-h host] [-u user] [-p pass] [-o outfile]\n  -or-\n$0 file user\@host:outfile\n";
}

scp(file => $file, host => $host, user => $user, pass => $pass, dest => $dest);

sub scp
{
	my %opts = @_;

	my $file = $opts{file};
	my $host = $opts{host};
	my $user = $opts{user} || 'root';
	my $pass = $opts{pass};
	my $dest = $opts{dest} || $file;

	warn "scp(): 'file' arg required" and return 0 if !$file;
	warn "scp(): 'host' arg required" and return 0 if !$host;
	warn "scp(): 'pass' arg required" and return 0 if !$pass;
	#warn "scp(): 'dest' arg required" and return 0 if !$dest;
	
	#warn "scp(): args: file=>$file, host=>$host, user=>$user, dest=>$dest\n";
	
	# Open SSH connection to host
	my $ssh = Net::SSH::Expect->new (
		host		=> $host,
		password	=> $pass,
		user		=> $user,
		raw_pty		=> 1,
	);
	
	# Execute login routine
	my $login_output = $ssh->login();

	# Get file mode info inorder to recreate on other end
	my $stat = (stat $file)[2] or die "Couln't stat $file: $!";
	my ($mode) = sprintf "%04o", $stat & 07777;

	my $buffer  = read_file($file);
	my $base64  = encode_base64($buffer);
	my @lines   = split /\n/, $base64;
	my $tmpfile = "/tmp/dat$$.uu";
	my @buffer  = map { "echo $_>>$tmpfile" } @lines;

	# TODO: Merge @lines into blocks of 4096 bytes with "echo -e" and encode newlines as \\n
	#my @buffer;
	#push @buffer, 'echo -e '.join('\\n', @lines).

	#die Dumper \@buffer;
	#write_file("/tmp/script.sh", map { $_."\n" } @buffer);
	
	# This routine here is a oneliner to brute force decode the base64-encoded data.
	# The core sub, decode_base64, was taken from MIME::Base64::Perl wholesale and stripped of whitespace/comments and edited to work in a single line
	my $uudecode_perl = '($c,$d,$e)=@ARGV;open F,$c or die"Couldnt open $c:$!";sub d6{local($^W)=0;use integer;$x=shift;$x=~tr|A-Za-z0-9+=/||cd;$x=~s/=+$//;$x=~tr|A-Za-z0-9+/| -_|;return""unless length $x;$u="";$l=length($x)-60;for($i=0;$i<=$l;$i+=60){$u.="M".substr($x,$i,60);}$x=substr($x,$i);if($x ne""){$u.=chr(32+length($x)*3/4).$x;}return unpack "u",$u};open OF,">$e"||die"Cant write $e:$!";binmode OF;while($z=<F>){print OF d6($z)}close F;chmod oct($d),$c if $d;unlink $c';
	
	my $cmd = "perl -e '$uudecode_perl' $tmpfile $mode $file";
	push @buffer, $cmd;

	my $out = ssh_command($ssh, join(';', @buffer));
	print "out:[$out]\n" if $out;
	
	$ssh->close();

	return 1;
}

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
