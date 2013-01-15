{package HashNet::MP::HubServerInstaller;

	use common::sense;
	
	use File::Copy;
	use File::Slurp;
	use File::Basename;
	use MIME::Base64::Perl;
	
	use HashNet::MP::MessageHub;
	use HashNet::Util::Logging;
	use HashNet::Util::MyNetSSHExpect;
	
	my $ssh_handle = undef;
	my %install_opts = ();
	
	my $only_testing = 0;
	
	sub install
	{
		my $class = shift;
		
		my %opts = @_;
		
		%install_opts = %opts;
		
		#trace "HubServerInstaller: install: \%install_opts: ".Dumper(\%install_opts);
		
		$only_testing = $opts{only_testing} || 0;
		
		my $app_src  = $opts{app_src}  || $0;
		my $app_dest = $opts{app_dest} || "/opt/hashnet/hubserver.bin";
		
		my $cfg_src  = $opts{cfg_src}  || undef; #'/etc/hashnet/hubserver.conf';
		my $cfg_dest = $opts{cfg_dest} || $cfg_src || '/etc/hashnet-hub.conf';
		
		$class->setup_connection(%opts) if $opts{host};
		
		# Steps:
		# 1. copy file to host/location (/opt/hashnet/hubserver.bin)
		# 2. create and copy config file 
		# 3. add watchdog to crontab if not present
		#	* * * * * root pgrep -f -x /root/dengpeersrv.bin >/dev/null 2>/dev/null || /usr/bin/screen -L -d -m -S dengpeersrv.bin /root/dengpeersrv.bin
		
		$class->copy_file($app_src, $app_dest);
		$class->write_config($cfg_src, $cfg_dest);
		$class->add_crontab_watchdog($app_dest);
		
		$class->close_connection() if $opts{host};
	}
	
	sub uninstall
	{
	
	}
	
	sub copy_file
	{
		my ($class, $src, $dest) = @_;
		if($ssh_handle)
		{
			my $cmd = "mkdir -p \`dirname $dest\`";
			trace "HubServerInstaller: add_crontab_watchdog [remote]: $cmd && scp $src $dest\n";
			
			unless($only_testing)
			{
				$ssh_handle->exec($cmd);
				$class->scp(file => $src, dest => $dest);
			}
		}
		else
		{
			trace "HubServerInstaller: add_crontab_watchdog [local]: copy('$src', '$dest')\n";
			
			copy($src, $dest) unless $only_testing;
		}
	}
	
	sub write_config
	{
		my ($class, $src, $dest) = @_;
		my $config = HashNet::MP::MessageHub->read_config($src);
		my $inf = $config->{node_info};
		delete $config->{config}->{auto_start};
		
		my @ips = split /\s*,\s*/, $inf->{lan_ips};
		my $ip = shift @ips;
		#$config->{config}->{seed_hubs} .= ', ' if $config->{config}->{seed_hubs};
		#$config->{config}->{seed_hubs} .= "$ip:8031";
		delete $config->{node_info};
		my $yaml = YAML::Tiny::Dump($config);
		
		trace "HubServerInstaller: write_config: New config: $yaml\n";
		
		trace "HubServerInstaller: write_config: src: $src, dest: $dest\n";
		
		unless($only_testing)
		{
			if($ssh_handle)
			{
				my $tmp_file = "/tmp/cfg$$.dat";
				write_file($tmp_file, $yaml);
				$class->scp(file => $tmp_file, dest => $dest);
			}
			else
			{
				write_file($dest, $yaml);
			}
		}
	}
	
	sub add_crontab_watchdog
	{
		my ($class, $app) = @_;
		
		my @parts = fileparse($app, qr/\.[^.]*/);
		my $app_base = $parts[0];
		
		my $crontab_line = " * * * * * root pgrep -f -x $app >/dev/null 2>/dev/null || /usr/bin/screen -L -d -m -S $app_base $app";
		my $file = '/etc/crontab';
		my $cmd = "grep -q '$crontab_line' $file; if [[ \$? -ne 0 ]]; then (echo '$crontab_line' >> $file;echo Added line to $file; service crond reload);else(echo Line already in $file);fi";
		
		trace "HubServerInstaller: add_crontab_watchdog: command: '$cmd'\n";
		unless($only_testing)
		{
			if($ssh_handle)
			{
				my $res = $ssh_handle->exec($cmd);
				trace "HubServerInstaller: add_crontab_watchdog [remote]: '$res'\n";
			}
			else
			{
				system($cmd);
			}
		}
	}
	
	sub close_connection
	{
		my $class = shift;
		trace "HubServerInstaller: close_connection: SSH logging out\n" if $ssh_handle;
		$ssh_handle->close() if $ssh_handle;
	}
	
	sub setup_connection
	{
		my $class = shift;
		
		my %opts = @_;
	
		my $host = $opts{host};
		my $user = $opts{user} || 'root';
		my $pass = $opts{pass} || '';
		
		#my $t = Benchmark::Timer->new();
	
		#warn "scp(): 'file' arg required" and return 0 if !$file;
		warn "scp(): 'host' arg required" and return 0 if !$host;
		#warn "scp(): 'pass' arg required" and return 0 if !$pass;
		#warn "scp(): 'dest' arg required" and return 0 if !$dest;
		
		#warn "scp(): args: file=>$file, host=>$host, user=>$user, dest=>$dest\n";
		trace "HubServerInstaller: setup_connection: Opening SSH connection: $user\@$host\n";
		
		#$t->start("login");
		
		# Open SSH connection to host
		$ssh_handle = Net::SSH::Expect->new (
			host		=> $host,
			password	=> $pass,
			user		=> $user,
			raw_pty		=> 1,
		);
		
		# Execute login routine
		my $login_output = $ssh_handle->login();
		
		trace "HubServerInstaller: setup_connection: Connected\n";
	}
	
	sub scp
	{
		my $class = shift;
		my %opts  = @_;
		
		use Net::SCP::Expect;
		my $scpe = Net::SCP::Expect->new;
		eval
		{
			trace "HubServerInstaller: scp $opts{file} $install_opts{user}\@$install_opts{host}:$opts{dest}\n";
			$scpe->login($install_opts{user}, $install_opts{pass});
			$scpe->scp($opts{file},$install_opts{host}.':'.$opts{dest});
		};
		if($@)
		{
			warn "Err: '$@'\n" unless $@ =~ /timed out while trying to connect/;
		}
		
# 		my $file = $opts{file};
# 		my $dest = $opts{dest} || $file;
# 		
# 		# Get file mode info inorder to recreate on other end
# 		my $stat = (stat $file)[2] or die "Couln't stat $file: $!";
# 		my ($mode) = sprintf "%04o", $stat & 07777;
# 	
# 		trace "HubServerInstaller: scp: $file -> $dest: Reading and base64-encoding $file\n";
# 		my $buffer  = read_file($file);
# 		
# 		my $tmpfile = "/tmp/dat$$.uu";
# 		my $pad_len = length("echo >>$tmpfile");
# 		my $base64  = encode_base64($buffer);
# 		my @lines   = split /\n/, $base64;
# 		my $length  = length($base64) + (scalar(@lines) * $pad_len);
# 		my @buffer  = map { "echo $_>>$tmpfile" } @lines;
# 		
#  		trace "HubServerInstaller: scp: $file -> $dest: Sending '$file', ".sprintf('%.02f Kb', $length /1024)." (base64 encoded), storing in tmpfile $tmpfile\n";
# # 		#$ssh_handle->send("echo $_>>$tmpfile") foreach @lines;
# # 		my $count = 0;
# # 		my $total_sent = 0;
# # 		my @tmpbuffer;
# # 		foreach my $line (@lines)
# # 		{
# # 			my $cmd = "echo $line>>$tmpfile";
# # 			push @tmpbuffer, $cmd;
# # 			$count += length($cmd);
# # 			if($count > 1024 * 100)
# # 			{
# # 				$total_sent += $count;
# # 				trace "HubServerInstaller: scp: $file -> $dest: \t Sending $count bytes ($total_sent bytes / $length bytes total) ...\n";
# # 				$ssh_handle->send(join(';', @tmpbuffer));
# # 				@tmpbuffer = ();
# # 				$count = 0;
# # 			}
# # 		}
# # 		
# # 		trace "HubServerInstaller: scp: $file -> $dest: \t Sending $count bytes...\n";
# # 		$ssh_handle->send(join(';', @tmpbuffer)) if @tmpbuffer;
# # 		trace "HubServerInstaller: scp: $file -> $dest: \t Transmit complete.\n";
# 		
# 		$ssh_handle->send(join(';', @buffer));
# 		trace "HubServerInstaller: scp: $file -> $dest: \t Transmit complete.\n";
# 		
# 		# TODO: Merge @lines into blocks of 4096 bytes with "echo -e" and encode newlines as \\n
# 		#my @buffer;
# 		#push @buffer, 'echo -e '.join('\\n', @lines).
# 	
# 		#die Dumper \@buffer;
# 		#write_file("/tmp/script.sh", map { $_."\n" } @buffer);
# 		
# 		# This routine here is a oneliner to brute force decode the base64-encoded data.
# 		# The core sub, decode_base64, was taken from MIME::Base64::Perl wholesale and stripped of whitespace/comments and edited to work in a single line
# 		my $uudecode_perl = '($c,$d,$e)=@ARGV;open F,$c or die"Couldnt open $c:$!";sub d6{local($^W)=0;use integer;$x=shift;$x=~tr|A-Za-z0-9+=/||cd;$x=~s/=+$//;$x=~tr|A-Za-z0-9+/| -_|;return""unless length $x;$u="";$l=length($x)-60;for($i=0;$i<=$l;$i+=60){$u.="M".substr($x,$i,60);}$x=substr($x,$i);if($x ne""){$u.=chr(32+length($x)*3/4).$x;}return unpack "u",$u};open OF,">$e"||die"Cant write $e:$!";binmode OF;while($z=<F>){print OF d6($z)}close F;chmod oct($d),$c if $d;unlink $c';
# 		
# 		trace "HubServerInstaller: scp: $file -> $dest: Executing perl one-liner Base64 decoder to decode $tmpfile to $dest, mode $mode\n";
# 		my $cmd = "perl -e '$uudecode_perl' $tmpfile $mode $dest";
# 		push @buffer, $cmd;
# 		$ssh_handle->send($cmd);
# 		
# 		my $buffer = join(';', @buffer);
# 		write_file("/tmp/script.sh", $buffer);
# 		
# 		#trace "HubServerInstaller: scp: Executing buffer: \n$buffer\n"; 
# 		trace "HubServerInstaller: scp: $file -> $dest: Done\n";
# 		#$ssh_handle->send($buffer);
# 		
		return 1;
	}
};

1;
