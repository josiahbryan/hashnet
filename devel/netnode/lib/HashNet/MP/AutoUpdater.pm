{package HashNet::MP::AutoUpdater;
	use common::sense;
	
	use HashNet::Util::Logging;
	use HashNet::MP::MessageQueues;
	use File::Copy;
	use File::Slurp;

	sub MSG_SOFTWARE_UPDATE { 'MSG_SOFTWARE_UPDATE' }
	sub MSG_SOFTWARE_UPDATE_QUERY { 'MSG_SOFTWARE_UPDATE_QUERY' }
	
	sub new
	{
		my $class = shift;
		my %opts = @_;

		$opts{master_pid}    ||= $$;      # for restarting
		$opts{startup_argv}  ||= \@ARGV;  # for restarting
		$opts{startup_app}   ||= $0;      # for restarting
		$opts{app_name}      ||= undef;   # for checking to see if the update or query is for "our app"
		$opts{app_ver}       ||= 0.0;     # for version checking/comparrison
		$opts{app_file}      ||= $0;      # for sending response to update quries
		$opts{hub_mode}      ||= 1;       # for socket message handlers
		
		if(!defined $opts{app_name})
		{
			my $app = $0;
			my ($path, $file) = $app =~ /(^.*?\/)([^\/]+)$/;
			$opts{app_name} = $file ? $file : $0;
		}
		
		trace "AutoUpdater: Starting update monitor for $opts{app_name}, current version $opts{app_ver}\n";
		
		my $self = bless \%opts, $class;
		
		$self->_setup_listener();
		
		return $self;
	}
	
	sub send_update
	{
		my $class = shift;
		my %opts = @_;
		
		$opts{sw} = $opts{ch}->sw if $opts{ch};
		
		my $sw   = $opts{sw} || 'HashNet::MP::SocketWorker';
		my $uuid = $opts{nxthop};
		if(!$sw && !$uuid)
		{
			trace "AutoUpdater: send_update(): No 'sw' (SocketWorker) and no 'nxthop' UUID given, unable to broadcast update\n";
			return undef;
		}
		
		if(!$opts{file})
		{
			trace "AutoUpdater: send_update(): No 'file' arg provided, unable to broadcast update\n";
			return undef;
		}
		
		if(!-f $opts{file})
		{
			trace "AutoUpdater: send_update(): File '$opts{file}' does not exist\n";
			return undef;
		}
		
		if(!$opts{app})
		{
			trace "AutoUpdater: send_update(): No app name given, unable to post update\n";
			return;
		}
		
		my $buffer = scalar(read_file($opts{file}));
		my $bytes = length($buffer);
		trace "AutoUpdater: send_update(): Creating update with file '$opts{file}' ($bytes bytes) for app $opts{app}, ver $opts{ver}\n";
		
		my $env = $sw->create_envelope(
			{
				ver  => $opts{ver},
				file => $opts{file},
				app  => $opts{app},
				len  => $bytes,
			},
			type   => MSG_SOFTWARE_UPDATE,
			nxthop => $uuid,
			bcast  => 1,
			_att   => $buffer,
		);
		
		my $qname = $opts{uuid} ? 'incoming' : 'outgoing';
		my $queue = msg_queue($qname);
		
		trace "AutoUpdater: send_update(): Posting ".$env->{type}."{".$env->{uuid}."} into queue '$qname'\n";
		$queue->add_row($env);
	}
	
	sub _setup_listener
	{
		my $self = shift;
		HashNet::MP::SocketWorker->reg_handlers(
			MSG_NODE_INFO => sub {

				my ($msg, $sw) = @_;

				if($msg->{data}->{type} eq 'client')
				{
					# No need to query a client, since two clients dont communicate, they would be different apps
					return 0;
				}

				my $app = $self->{app_name};
				my $ver = $self->{app_ver};

				my $env = $sw->create_envelope(
					{
						ver  => $ver,
						app  => $app,
					},
					type   => MSG_SOFTWARE_UPDATE_QUERY,
					#to     => $msg->{from},
					nxthop => $msg->{from},
					bcast  => 1,
				);

				trace "AutoUpdater: MSG_NODE_INFO: Posting ".$env->{type}."{".$env->{uuid}."} to peer {$msg->{from}}\n";
				$sw->outgoing_queue->add_row($env);

				# We're just hooking into MSG_NODE_INFO to trigger a query, we never (cross fingers) would need to consume this...
				return 0;
			},

			MSG_SOFTWARE_UPDATE_QUERY => sub {
				my $msg = shift;
				my $sw  = shift;
				
				my $data = $msg->{data};

				my $app = $self->{app_name};
				my $ver = $self->{app_ver};
				my $new_app = $data->{app};
				my $new_ver = $data->{ver};

				if($app ne $new_app)
				{
					trace "AutoUpdater: MSG_SOFTWARE_UPDATE_QUERY: Not responding, update query is for app '$new_app', not '$app'\n";
				}
				elsif($ver <= $new_ver)
				{
					trace "AutoUpdater: MSG_SOFTWARE_UPDATE_QUERY: Not responding, current '$ver' is older or same as query version '$new_ver'\n";
				}
				else
				{
					my $file = $self->{app_file};
					my $buffer = scalar(read_file($file));
					my $bytes = length($buffer);
					trace "AutoUpdater: MSG_SOFTWARE_UPDATE_QUERY: Responding with file '$file' ($bytes bytes) for app $app, ver $ver\n";

					my $env = $sw->create_envelope(
						{
							ver  => $ver,
							file => $file,
							app  => $app,
							len  => $bytes,
						},
						type   => MSG_SOFTWARE_UPDATE,
						to     => $msg->{from}, # NOTE: send_update() sends as bcast, we send directly to requesting peer
						_att   => $buffer,
					);

					trace "AutoUpdater: MSG_SOFTWARE_UPDATE_QUERY: Posting ".$env->{type}."{".$env->{uuid}."} to peer {$msg->{from}}\n";
					$sw->outgoing_queue->add_row($env);

					# We return 1 regardless of {hub_mode} because even in a hub, we want to consume this update query
					# because we responded to it - the client doesnt need multiple responses, only one.
					return 1;
				}

				return 1 if !$self->{hub_mode};
			},
							
			MSG_SOFTWARE_UPDATE => sub {
				my $msg = shift;

				trace "AutoUpdater: MSG_SOFTWARE_UPDATE: Received new update message, checking\n";
				
				my $data = $msg->{data};
				
				my $app = $self->{app_name};
				my $ver = $self->{app_ver};
				my $new_app = $data->{app};
				my $new_ver = $data->{ver};
				
				if($app ne $new_app)
				{
					trace "AutoUpdater: MSG_SOFTWARE_UPDATE: Not updating, update is for app '$new_app', not '$app'\n";
				}
				elsif($new_ver <= $ver)
				{
					trace "AutoUpdater: MSG_SOFTWARE_UPDATE: Not updating, new version '$new_ver' is older or same as current version '$ver'\n";
				}
				else
				{
					my $tmp = $app.'.tmp';
					my $exp_len = $data->{len};
					my $buffer = $msg->{_att};
					my $len = length($buffer);
					if($len != $exp_len)
					{
						trace "AutoUpdater: MSG_SOFTWARE_UPDATE: Not updating, transmission bad, expected $exp_len bytes, only have $len bytes\n";
					}
					else
					{
						trace "AutoUpdater: MSG_SOFTWARE_UPDATE: Updating software, writing to '$tmp'\n";
						write_file($tmp, $msg->{_att});
						
						trace "AutoUpdater: MSG_SOFTWARE_UPDATE: Moving '$tmp' to '$app'\n";
						move($tmp, $app);
						
						system("chmod +x $app");
						
# 						trace "AutoUpdater: MSG_SOFTWARE_UPDATE: Storing update for routing on restart\n";
# 						# hack: Hold lock while we kill the process.
# 						# - this prevents the router from starting to route the update and not finishing if we kill it
# 						# - this lock will be cleared when the app restarts since the lock will show as stale
# 						incoming_queue()->lock_file; 
# 						incoming_queue()->add_row($msg) if $self->{hub_mode};
						
						trace "AutoUpdater: MSG_SOFTWARE_UPDATE: Requesting restart\n";
						$self->rexec_app;
					}
				}
					
				
				# retval of 1 tells SocketWorker to not add $msg to incoming queue
				return 1 if !$self->{hub_mode};
			},
		);
	}

	sub kill_children
	{
		my $self = shift;
		my @pids = grep { $_ != $$ && $_ != $self->{master_pid} } _get_kids($self->{master_pid});
		
		trace "AutoUpdater: kill_children(): Master PID: $self->{master_pid}, found children PIDs: @pids\n";
		kill 15, $_ foreach @pids;
		
		trace "AutoUpdater: kill_children(): Kids killed\n";
	}

	sub rexec_app
	{
		my $self = shift;
		
		info "AutoUpdater: request_restart(): Restart requested\n";
		
		$self->kill_children();
		
		if(!fork)
		{
			# Fork off the actual code to restart the process
			my @startup_argv = @{ $self->{startup_argv} || [] };
			
			my $app = $self->{startup_app};
			$app =~ s/#.*$//g; # remove any comments from the app name
			my $cmd = "$^X $app @startup_argv &";
			
			logmsg "INFO", "AutoUpdater: request_restart(): In monitor fork $$, executing restart command: '$cmd'\n";
			system($cmd);
			exit;
		}
		else
		{
			#info "AutoUpdater: request_restart(): Waiting a few moments to kill $self->{master_pid}\n";
			#sleep 5;
			
			# Kill the master process
			info "AutoUpdater: request_restart(): Killing master process $self->{master_pid}\n";
			kill 15, $self->{master_pid}; # 15 = SIGTERM
			
			info "AutoUpdater: request_restart(): Killing self $$\n";
			kill 15, $$;
		}
	};
	
	sub _get_kids
	{
		my $pid = shift;
		
		# We'll first make a hash %h where:
		# each key is the PID of a process
		# each value is a list of the PIDs of the sub-process (direct descendant (ie: children) only, no grand child,...)
		
		# we'll loop on all files under /proc, and take only those whose filename is a number
		opendir(DIR,"/proc/") or die ("Can't list proc");
		my $file;
		my %h=(); # key=pid, value=list of children
		while($file=readdir(DIR))
		{
			#print "Trying $file...\n";
			next unless $file =~ m/^\d+$/;  # only numbers
			my $stat = "/proc/$file/stat";
			#print "Reading $stat\n";
			if(!open(STAT,$stat)) # open the stat file for this process
			{
				warn "Cannot read $stat: $!";
				next;
			}
			my $s=<STAT>;
			my @f=split(/\s+/,$s);
			# pid: $f[0]   parent PID: $f[3]
			my $pid = $f[0] || 0;
			my $ppid = $f[3] || 0;
			#print "\t $ppid -> $pid [[".join('|',@f)."]]\n";
			next if !$pid;
			next if !$ppid;
			push @{ $h{$ppid} },$pid;
			close(STAT);
		}
		closedir(DIR);
		
		my @pids=();
		
		# recursive function to add a pid and the PIDs of children, grand-children,...
		my $add; $add = sub
		{
			push @pids, $_[0];
			map { $add->($_) } @{ $h{$_[0]} } if (defined($h{$_[0] || ''}));
		};
		# print join("n", map { $_ . ':' . join(',',sort @{ $h{$_}  } )} sort keys %h);
		
		$add->($pid);
		
		# output results
		#print join(' ',grep { defined $_ } @pids)."\n";
		return @pids;	
	}

}
1;
