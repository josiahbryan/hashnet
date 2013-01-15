{package HashNet::MP::HubServerInstaller;

	use common::sense;
	
	use File::Copy;
	use File::Slurp;
	use File::Basename;
	use MIME::Base64::Perl;
	
	# Our version of SCP didnt work for largeish (>=800Kb) files :(
	use Net::SCP::Expect;
		
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
		eval { $ssh_handle->close() if $ssh_handle; };
	}
	
	sub setup_connection
	{
		my $class = shift;
		
		my %opts = @_;
	
		my $host = $opts{host};
		my $user = $opts{user} || 'root';
		my $pass = $opts{pass} || '';
		
		warn "scp(): 'host' arg required" and return 0 if !$host;
		
		#warn "scp(): args: file=>$file, host=>$host, user=>$user, dest=>$dest\n";
		trace "HubServerInstaller: setup_connection: Opening SSH connection: $user\@$host\n";
		
		# Open SSH connection to host
		$ssh_handle = Net::SSH::Expect->new (
			host		=> $host,
			password	=> $pass,
			user		=> $user,
			raw_pty		=> 1,
		);
		
		$ssh_handle->login();
		
		trace "HubServerInstaller: setup_connection: Connected\n";
	}
	
	sub scp
	{
		my $class = shift;
		my %opts  = @_;
		
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
		
		return 1;
	}
};

1;
