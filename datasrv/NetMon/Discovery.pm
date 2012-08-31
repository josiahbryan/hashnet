#!/usr/bin/perl
# Discovery.pm - based on discovery.pl, updated by JB 20120823
# discovery.pl - Forked subnet discovery/scanner
# Author: Josiah Bryan <josiahbryan@gmail.com>
# 2009-03-02
use strict;

=head1 NAME

NetMon::Discovery - A forked subnet discovery/scanner.

=head1 SYNOPSIS

use NetMon::Discovery;

my @ip_list = NetMon::Discovery->ping_local_network();

# @ip_list now contains all local IPs discovered


=cut

=head1 DESCRIPTION

This program quickly discovers and scans as many subnets as possible.

The program breaks itself into a series of forked processes ('threads') 
to do the scanning, broadcast pinging, etc. It all starts with the IP
address of the machine on which its run - from there, it attempts to 
broadcast ping the subnet to discover any other active Class C subnets,
and proceedes to do a quick scan of every IP address in each Class C
subnet discovered. The main thread just sits back and waits for all the
other threads to finish, the reads the cache files and collates the list
using a hashmap and presents the output in a nice pretty list. Supposedly.

Anyway, block diagram time:

	+--------------------------+					   +--> [ Fork BroadCastPing ] --> [ Cache File ]
	| Read IP Config `ifconfig`| --> [ SubnetManager->found_ip() ] --> |--> [ Fork Result Reader for BroadcastPing] --> [ SubnetManager->found_ip() ] for each broadcast IP received
	+--------------------------+ 					   |--> [ Fork SubnetScanner ] --> [ Cache File ]
									   +--> [ Return to Main Thread ] -> [ Wait for All Forks ] -> [ Read Caches ] -> [ map() ] -> [ Print List ]

Sorry, not very pretty - but hey, too lazy to whip out Graphviz just yet - maybe later.

=cut

=head2 MetMon::Util

NetMon::Util - Utility methods, primarily file locking.

=cut

package NetMon::Util;
{
	use Time::HiRes qw/sleep time/;
	use POSIX;
	use Cwd qw/abs_path/;
		
	sub lock_file
	{
		my $file  = shift;
		my $max   = shift || 5;
		my $speed = shift || .01;
		
		my $result;
		my $time  = time;
		my $fh;
		
		#$file = abs_path($file);
		
		#stdout::debug("Util: +++locking $file\n");
		sleep $speed while time-$time < $max && 
			!( $result = sysopen($fh, $file.'.lock', O_WRONLY|O_EXCL|O_CREAT));
		#stdout::debug("Util: lock wait done on $file, result='$result'\n");
		
		#die "Can't open lockfile $file.lock: $!" if !$result;
		warn "Can't open lockfile $file.lock: $!" if !$result;
		
		return $result;
	}
	
	sub unlock_file
	{
		my $file = shift;
		#$file = abs_path($file);
		#stdout::debug("Util: -UNlocking $file\n");
		unlink($file.'.lock');
	}
};

=head2 stdout

stdout - debug() and info() methods for output to the console

=cut

package stdout;
{	
	use Time::HiRes qw/time/;
	
	my $stdout_lock = '.stdout';
	
	sub lock_stdout()
	{
		#NetMon::Util::lock_file($stdout_lock);
	}
	
	sub unlock_stdout() 
	{
		#NetMon::Util::unlock_file($stdout_lock);
	}
	
	sub debug { lock_stdout; print sprintf('%.09f',time())." [DEBUG] [PID $$] \t". join('', @_); unlock_stdout }
	sub info  { lock_stdout; print sprintf('%.09f',time())." [INFO]  [PID $$] \t". join('', @_); unlock_stdout }
}

=head2 NetMon::Discovery::SubnetManager

A thread-safe subnet list manager. This package manages the list 
of discovered subnets and initiates broadcast pings (C<BroadcastPing> package)
and simple Class C subnet scans (C<SubnetScanner> package) for each subnet
found.

Primary interface to this package is through the C<found_ip($ip)> method -
the package takes care of everything else internally.

The blessed handle returned by C<new()> is safe to pass across threads,
since it implements an internal file-based state cache to sync the 
subnet list across related processes.

At any point, you can use the C<subnets()> method to retrieve a hashref
of the discovered subnets.

=cut

package NetMon::Discovery::SubnetManager;
{
	use Time::HiRes qw/sleep/;
	use Data::Dumper;
	#use POSIX;
	#use Fcntl qw(:flock); 

=head3 SubnetManager Methods

=over 12

=item NetMon::Discovery::SubnetManager->new()

Returns a blessed reference to a new SubnetManager object. Use C<found_ip($ip)>
to add possible subnet candidates to this object.

=cut

	sub new
	{
		my $class = shift;
		my $cache = '.subnetmanager.thread';
		unlink($cache);
		
		return bless 
			{ 
				subnets 	=> {}, 
				cache 		=> $cache,
				#cache_lock	=> $cache.'.lock',
				cache_mtime	=> undef,
				cache_size	=> undef,
			}, $class;
	}

=item $mgr->subnets()

Returns a hashref of subnets, with the first 
three octects of the Class-C subnet IP as the key.

=cut

	sub subnets { shift->{subnets} }
	
	# Determine if the cache is dirty by checking the mtime AND the size -
	# if either changed, assume cache was updated by another process.
	sub _cache_dirty
	{
		my $self = shift;
		my $cache = $self->{cache};
		if(-f $cache && (
			(stat($cache))[9]  != $self->{cache_mtime} || 
			(stat(_))[7]       != $self->{cache_size}
		))
		{
			return 1;
		}
		
		return 0;
	}
	
	# Lock cache exclusivly, and read cache in if changed.
	sub _sync_cache_in
	{
		my $self = shift;
		my $cache = $self->{cache};
		
		$self->_lock_cache;
		
		if($self->_cache_dirty)
		{
			stdout::debug("SubnetManager: Subnet cache dirty, reloading\n");
			
			$self->{subnets} = {};
			my ($base,$ip,$bcast);
			
			open(CACHE_FH," < $cache") || die "SubnetManager: Cannot open state cache '$cache': $!";
			while(<CACHE_FH>)
			{
				s/[\r\n]//g;
				($base,$ip,$bcast) = split /,/;
				$self->{subnets}->{$base} = { ip => $ip || '', bcast => $bcast || '' };
			}
			close(CACHE_FH);
		}
	}
	
	# Flush cache to disk, unlock cache.
	sub _sync_cache_out
	{
		my $self = shift;
		
		my $subnet_data = $self->{subnets};
		my @keys = keys %{$subnet_data};
		
		my $cache = $self->{cache};
		
		open(F,">$cache") or die "SubnetManager: Cannot open state cache '$cache': $!";
		print F join "\n", map { join ',', $_, $subnet_data->{$_}->{ip}, $subnet_data->{$_}->{bcast} } @keys;
		close(F);
		
		# Store our cache size/time in memory, so if another fork changes
		# the cache, sync_in() will notice the change and reload the cache
		$self->{cache_mtime} = (stat($cache))[9];
		$self->{cache_size}  = (stat(_))[7];
		
		# Release lock on cache
		$self->_unlock_cache;
	}
	
	# Handle cache locking.
	# Word about locking:
	# I tried to be a good perl programmer and use flock, since this does run over an NFS share most of the time.
	# However, it took subsequent threads between 1 and 30 seconds to detect an unlock - thats a long time when I'm
	# trying to create a *quick* scanner. So, I implemented a quick-and-dirty lock utility based on the sysopen()
	# method from http://perldoc.perl.org/perlfaq5.html#Why-can%27t-I-just-open(FH%2c-%22%3Efile.lock%22)%3f
	# It seems to "work" - and locks are detected just as quick as Time::HiRes allows - see the NetMon::Util package
	# for the code (way at the top of this file.)
	sub _lock_cache 
	{
		my $self = shift;
		#stdout::debug("SubnetManager: --> Going to lock $self->{cache}\n");
		#open $self->{cache_lock_fh}, "> $self->{cache_lock}" or die "SubnetMannager: Can't open cache lock file '$self->{cache_lock}': $!";
		#flock $self->{cache_lock_fh}, LOCK_EX or die "SubnetMannager: Can't get exclusive lock on cache lock file '$self->{cache_lock}': $!";
		NetMon::Util::lock_file($self->{cache});
		#stdout::debug("SubnetManager: <-- LOCKED $self->{cache}\n");
		
	}
	
	# Unlock the cache.
	sub _unlock_cache 
	{ 
		my $self = shift;
		#close $self->{cache_lock_fh};
		NetMon::Util::unlock_file($self->{cache});
		#stdout::debug("SubnetManager: +++ Unlocked $self->{cache}\n");
	}

=item $mgr->found_ip($ip,$bcast=undef)

Extracts the first three octects from IP $ip and checks to see if we've seen this Class C subnet yet.
If already seen, it just returns undef. If NOT already seen (a new subnet), then we start a C<SubnetScanner>
on the new subnet. 

Additionally, if a broadcast IP is provided ($bcast), then we create a new C<BroadcastPing> to grab any 
results from the ping available. 

Now here's the fun part - inorder to discover other active Class C subnets if, for example, we really are on
a class A subnet, we listen to the results of the C<BroadcastPing> using the $reader object given. When the
results are available from the ping, we feed the IP addresses returned from the ping back through into 
ourself thru C<found_ip($ip)>, allowing our code to check to see if any hosts that responded to the broadcast
ping are from a heretofore-unseen Class-C subnet that we can also explore. 

And, since (we think) we are thread safe, even though we're in another forked process while waiting for the 
results, any new subnets we find are propogated to all process that hold a C<SubnetManager> object automatically.

=cut

	sub found_ip
	{
		my $self  = shift;
		my $ip    = shift;
		my $bcast = shift;
		
		return undef if !$ip;
		my ($base,$last_octet) = $ip =~ /(\d{1,3}\.\d{1,3}\.\d{1,3})\.(\d{1,3})/;
		
		# Lock cache, reload cache if dirty
		$self->_sync_cache_in();
		
		if( !$base || !$last_octet || $self->{subnets}->{$base} || $base =~ /\.255$/)
		{
			$self->_unlock_cache();
			return undef;
		}
		
		stdout::info("SubnetManager: Found new subnet $base.0/24, adding to list.\n");
		
		$self->{subnets}->{$base} = { ip => $ip, bcast => $bcast || ''};
		
		# Flush cache to disk, unlock cache
		$self->_sync_cache_out();
		
		# Start scanning the subnet
		NetMon::Discovery::SubnetScanner->new_subnet($base);
		
		# If we have a broadcast address, broadcast ping the subnet and grab any new hosts 
		# to see if there are new class-C subnets that we can scan
		if($bcast)
		{
			my $reader = NetMon::Discovery::BroadcastPing->new_broadcast($bcast,$base);
			
			if(my $pid = fork)
			{
				# no cache file for this thread
				NetMon::Discovery::ThreadManager->add_thread($pid,undef,'SubnetManager');  #string at end is just for debugging
			}
			else
			{
				stdout::debug("SubnetManager: Waiting for broadcast results, using broadcast reader $reader->{cache}...\n");
				
				my $start = time;
				my $max_time = 60 * 5;
				
				# Timeout after $max_time of no results
				sleep .1 while ! $reader->has_results && time - $start < $max_time;
				
				if($reader->has_results)
				{
					stdout::debug("SubnetManager: Broadcast results received, loading.\n");
					
					# Feed the found ip addresses back into ourself to scan any new subnets found
					my @ip_list  = $reader->bcast_results;
					#stdout::debug("SubnetManager: \@ip_list=".Dumper(\@ip_list));
					$self->found_ip($_) foreach @ip_list;
				}
				else
				{
					stdout::debug("SubnetManager: No broadcast ping results received.\n");
				}
				
				NetMon::Discovery::ThreadManager->exit_thread('SubnetManager'); # string arg is just for debugging
			}
			
		}
		
		return $base;
		
	}

}

=back

=head2 NetMon::Discovery::BroadcastPing

Sends an adaptive broadcast ping to a specified subnet
and gathers the results, providing a reader object 
that can be used to fetch the results on request.

=cut

package NetMon::Discovery::BroadcastPing;
{

=head3 BroadcastPing Methods

=over 12

=item NetMon::Discovery::BroadcastPing->new_broadcast($broadcast_address, $base_ip_address)

Use the 'ping' command to send an 'adaptive' broadcast ping to $broadcast_address, and stores
the results in a cache indexed by $base_ip_address. It indixes the cache by the base IP rather
than the broadcast IP so that the SubnetScanner package can implicitly know what cache to 
give to the result_reader() method when checking for broadcast ping results.

Automatically forks a new process for running the ping and collecting the results. It registers
itself with the ThreadManager as needed.

Returns a new NetMon::Discovery::BroadcastPing reader object.

=cut

	sub new_broadcast
	{
		my $class = shift;
		my $bcast = shift;
		my $base  = shift;
		
		# Store results in a cache indexed by $base ip address instead of $bcast, 
		# so that the subnet scanner knows where to look for the results - since
		# every subnet scanner instance will have a base IP, but not every subnet
		# scan will have a broadcast IP. (e.g. subnets found from a broadcast ping, etc)
		
		# $tmp_cache is the initial cache written to by `ping` - we write to $tmp_cache
		# so that we can perform maping and dup elimination before writing to the real
		# thread cache '$cache' used by other threads and the main thread to read results.
		my $tmp_cache   = ".bcast.tmp.$base.thread";
		unlink($tmp_cache);
		
		my $cache = ".bcast.$base.thread";
		unlink($cache);
		
		if(my $pid = fork)
		{
			stdout::debug("BroadcastPing: Forked Thread: $cache\n");
			NetMon::Discovery::ThreadManager->add_thread($pid, $cache, 'BroadcastPing');
			
			return $class->result_reader($cache);
		}
		else
		{
			# Gather the IPs on this subnet
			system("ping -A -b $bcast -c 255 -w 2 -W 1 2>/dev/null > $tmp_cache");
			
			# De-duplicate found IP and dump to $cache - subnet scanner and subnetmanager then read $cache 
			# to get results of the broadcast ping
			my %collation_map;
			my $ip_regex = $NetMon::Discovery::ip_regex;
			
			my @lines = `cat $tmp_cache`;
			stdout::debug("BroadcastPing: Read ".scalar(@lines)." lines from $cache\n");
			
			foreach(@lines)	
			{
				$collation_map{$1} ++ if /($ip_regex)/;
			}
			
			# Sort not *needed* but makes debugging prettier/nicer when wanted
			my @keys = sort keys %collation_map;
			
			stdout::debug("BroadcastPing: Writing ".scalar(@keys)." lines to $cache\n");
			
			NetMon::Util::lock_file($cache);
			
			open(FILE, ">$cache") || die "BroadcastPing: Cannot write ping results to '$cache': $!";
			print FILE join "\n", @keys;
			close(FILE);
			
			NetMon::Util::unlock_file($cache);
			
			stdout::debug("BroadcastPing: End broadcast read $bcast\n");
			NetMon::Discovery::ThreadManager->exit_thread('BroadcastPing');
		}
	}
	
	########
	# The rest of these methods in this package comprise a simple reader object
	# used to read the results of the boardcast ping cache file.
	########

=item NetMon::Discovery::BroadcastPing->result_reader($cache_file)

Constructs a new NetMon::Discovery::BroadcastPing reader object and returns a blessed reference.
You can either give it the first three octects of the subnet you're watching for the broadcast from,
or give it the relative cache file. Right now, this assumes that the filename must start with '.' -
hackish, I know - should be formalized/changed for 'production.'

=cut

	sub result_reader
	{
		my $class = shift;
		my $cache = shift;
		if($cache !~ /^\./)
		{
			$cache = ".bcast.$cache.thread";
		}
		bless { cache => $cache }, $class;
	}

=item $reader->has_results()

Returns true if their are results ready to be read from the broadcast ping.

=cut

	sub has_results
	{
		my $self = shift;
		my $file = $self->{cache};
		return -f $file && (stat($file))[7] > 5; # arbitrary size
	}

=item $reader->bcast_results()

Returns undef if has_results() is false, otherwise returns the results of the broadcast ping.
In an array contents, returns a list of IPs. In a scalar context, returns a hashref of
ip addresses, with the IP being the key and a true value as the value.

=cut

	sub bcast_results
	{
		my $self = shift;
		return undef if ! $self->has_results;
		
		my $file = $self->{cache};
		
		NetMon::Util::lock_file($file);
			
		stdout::debug("bcast_results: Thread $$ reading $file ...\n");
		my @file = `cat $file`;
		
		NetMon::Util::unlock_file($file);
		
		s/[\r\n]//g foreach @file;
		return wantarray ? @file : { map { $_ => 1 } @file };
	}

}

=back

=head2 NetMon::Discovery::SubnetScanner

NetMon::Discovery::SubnetScanner - Does the actual scanning of the Class C subnet given.

=cut

package NetMon::Discovery::SubnetScanner;
{
	use Data::Dumper;
	use Time::HiRes qw/sleep/;
	use Parallel::ForkManager;
	use Net::Ping;
	
	# Variable: $MAX_FORKS - The max number of forks to allow for the scanner
	our $MAX_FORKS    = 32 * 2;
	
	# Variable: $PING_TIMEOUT - Timeout for the pings before an ip is considered 'down'/offline/whatever
	our $PING_TIMEOUT =  1.9;
	
	# Variable: $PING_WAIT - The time to wait *between* pings - yield time, basically
	our $PING_WAIT    =  0.1;
	#stdout::debug("SubnetScanner: \$PING_TIMEOUT=$PING_TIMEOUT, \$MAX_FORKS=$MAX_FORKS\n");
	
	my $p = Net::Ping->new('tcp');
	$p->hires(1);

=head3 SubnetScanner Methods

=over 12

=item NetMon::Discovery::SubnetScanner->new_subnet($base)

Forks the scanning routines into a new thread and registers the thread and cache file
with the C<ThreadManager>.

=cut

	sub new_subnet
	{
		my $class = shift;
		my $base = shift;
		
		my $cache = ".subnet.$base.thread";
		unlink($cache);
		
		if(my $pid = fork)
		{
			NetMon::Discovery::ThreadManager->add_thread($pid, $cache, 'SubnetScanner');
		}
		else
		{
			$class->_scan_subnet($base,$cache);
			NetMon::Discovery::ThreadManager->exit_thread('SubnetScanner');
		}
	}
	
	# Scan the Class-C subnet specified by $subnet_prefix and store results into $scan_cache.
	# $from and $to are optional - future expansion, really.
	# Uses L<Parallel::ForkManager> to manage parallel scanning.
	sub _scan_subnet
	{
		my $class = shift;
		my $subnet_prefix = shift;
		my $scan_cache = shift;
		
		my ($from,$to) = @_;
		$from ||= 1;
		$to   ||= 254;
		
		my $bcast_reader = NetMon::Discovery::BroadcastPing->result_reader($subnet_prefix);
		my $validated_cache = undef;
		
		stdout::debug("SubnetScanner: Subnet '$subnet_prefix.0/24' scan started, created broadcast reader $bcast_reader->{cache}...\n");
		
		my $pm = Parallel::ForkManager->new($MAX_FORKS);
		
		my $target_ip;
		for my $ip4 ($from .. $to)
		{
			$target_ip = join '.', $subnet_prefix, $ip4;
			
			# Skip any IPs already found to be valid from the broadcast ping
			if($validated_cache)
			{
				next if $validated_cache->{$target_ip};
			}
			else
			{	
				if($bcast_reader->has_results)
				{
					stdout::debug("SubnetScanner: '$subnet_prefix.0/24' broadcast results received\n");
					$validated_cache = $bcast_reader->bcast_results;
					#stdout::debug("SubnetScanner: \$validated_cache = ".Dumper($validated_cache));
				}
			}
	
			$pm->start and next;
			
			if($p->ping($target_ip,$PING_TIMEOUT))
			{
				NetMon::Util::lock_file($scan_cache)   if $MAX_FORKS > 1;
				
				system("echo $target_ip >> $scan_cache");
				stdout::info("SubnetScanner: [$subnet_prefix.0/24] ++ $target_ip\n");
				
				NetMon::Util::unlock_file($scan_cache) if $MAX_FORKS > 1;
				
			}
			
			sleep $PING_WAIT;
			$pm->finish;
		}
		
		$pm->wait_all_children;
		stdout::debug("SubnetScanner: Subnet '$subnet_prefix.0/24' read done\n");
	}
}

=back

=head2 NetMon::Discovery::ThreadManager

Coordinates all the threads used in discovery and the
associated result cache files. Note that this
package should be thread-safe, as it syncs its state
accross threads. This is so that forked processes
can in turn fork other processes, and the main thread
will correctly receive the result file locations for
each thread.

=cut

package NetMon::Discovery::ThreadManager;
{
	use Data::Dumper;
	
	my @thread_list;
	my @file_list;
	
	my $cache = ".threadmgr.thread";
	unlink($cache);
	
	my $cache_mtime	= 0;
	my $cache_size	= 0;
	
	my $CREATE_PID = $$;
	
	sub _cache_dirty
	{
		if(-f $cache && (
			(stat($cache))[9]  != $cache_mtime || 
			(stat(_))[7]       != $cache_size
		))
		{
			return 1;
		}
		
		return 0;
	}
	
	sub _lock_cache 
	{
		NetMon::Util::lock_file($cache);
	}
	
	sub _unlock_cache 
	{ 
		NetMon::Util::unlock_file($cache);
	}
	
	
	sub _sync_cache_in
	{
		_lock_cache();
		
		if(_cache_dirty())
		{
			stdout::debug("ThreadManager: Cache dirty, reloading\n");
			@thread_list = ();
			@file_list = ();
			open(CACHE_FH, "< $cache") || die "ThreadManager: Cannot open state cache '$cache': $!";
			while(<CACHE_FH>)
			{
				s/(^\s+|\s+$|[\r\n])//g;
				next if !$_;
				if(/^[\d]+$/)
				{
					push @thread_list, $_;
				}
				else
				{
					push @file_list, $_;
				}
			}
			close(CACHE_FH);
		}
		
	}
	
	sub _sync_cache_out
	{
		my $self = shift;
		
		open(F,">$cache") || die "ThreadManager: Cannot open state cache '$cache': $!";
		print F join "\n", @thread_list;
		print F "\n"    if @thread_list;
		print F join "\n", @file_list;
		print F "\n"    if @file_list;
		close(F);
		
		# Store our cache size/time in memory, so if another fork changes
		# the cache, sync_in() will notice the change and reload the cache
		$cache_mtime = (stat($cache))[9];
		$cache_size  = (stat(_))[7];
		
		_unlock_cache();
	}

=head3 ThreadManager Methods 

=over 12

=item NetMon::Discovery::ThreadManager->wait_all()

Attempt for all child threads to finish 
before returning.

=cut

	sub wait_all
	{
		die "You are in a child process - wait_all() only works in the main thread ($$ != $CREATE_PID)" if $$ != $CREATE_PID; 
		
		while(@thread_list && (my $pid = wait) > 0)
		{
			_sync_cache_in();
			@thread_list = grep { $_ != $pid } @thread_list;
			stdout::debug("ThreadManager: wait_all(): Collected thread $pid, ".scalar(@thread_list)." thread left\n");
			_sync_cache_out();
		}
		
		_sync_cache_in();
		@thread_list = ();
		_sync_cache_out();
	}

	
=item NetMon::Discovery::ThreadManager->add_thread($pid,$file,$thread_name)

Add thread $pid to the list of active threads, with result file $file as 
the data cache output to load in the main thread. $thread_name is just used
for debugging output.

=cut

	sub add_thread
	{
		my $class = shift;
		my ($pid,$file,$thread_name)  = @_;
		
		_sync_cache_in();
		push @thread_list, $pid if $pid;
		push @file_list, $file if $file;
		stdout::debug("$thread_name: add_thread():  ".($pid ? "Added thread $pid, ":"").scalar(@thread_list)." threads running ".($file ? "(added file $file)" : '')."\n");
		_sync_cache_out();
		
		return $pid || $file;
	}
	
=item NetMon::Discovery::ThreadManager->exit_thread($thread_name = undef)

Call from your child threads to remove your processe's pid from the list 
of active threads and exit the child process. This will NOT return due 
to the exit() call.

=cut

	sub exit_thread()
	{
		my $class = shift;
		my $thread_name = shift;
		
		_sync_cache_in();
		@thread_list = grep { $_ != $$ } @thread_list;
		stdout::debug("$thread_name: exit_thread(): Exiting thread $$, ".scalar(@thread_list)." thread left\n");
		_sync_cache_out();
		
		exit 0;
	}
	
=item NetMon::Discovery::ThreadManager->files()

Returns a list of all result files added with C<add_thread()>

=cut

	sub files
	{
		@file_list;
	}
};

=back

=head2 NetMon::Discovery

NetMon::Discovery - Main program flow and logic.

Discoveres the primary IP address on the system using a very simple grep 
on `ifconfig`. From there, it adds any found IPs to the C<SubnetManager>
using C<found_ip($ip,$bcast)>.

We also read '/etc/resolv.conf' to see if the nameserver is on a different
subnet that we can explore.

At one point, I had it reading the ARP table (arp -a), but I've turned
that off for now - maybe later.

Oh, and YES I know the $ip_regex is loose and allows 999.999.999.999, etc,
through - but, frankely, the IP on your box should be valid anyway since
it's coming fromt the system and not user input. (Yeah, I know, trust
nobody - I'll fix the regex later.)

=cut

package NetMon::Discovery;
{
	use Data::Dumper;
	use Socket;
	
	our $ip_regex = '\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}';
		
	sub ping_local_network
	{
		#use NetMon;
		#use NetMon::Classifier;
		
		# SubetManager manages its list of found subnets correctly across
		# forks using a file-based cache thats reloaded when another thread
		# changes it (by adding a new subnet thru found_ip())
		our $subnet_manager = NetMon::Discovery::SubnetManager->new();
			
		read_ifconfig($subnet_manager);
		read_dns_config($subnet_manager);
		#read_arptable($subnet_manager);
		
		stdout::info("Main: Waiting for all threads to finish.\n");
		NetMon::Discovery::ThreadManager->wait_all;
		stdout::info("Main: All threads done, reading and classifying...\n");
		
		my @files = NetMon::Discovery::ThreadManager->files;
		
		my %ip_mapper;
		foreach my $cache (@files)
		{
			stdout::debug("Main: Reading cache $cache\n");
			my @lines = `cat $cache`;
			my $ip;
			foreach(@lines)	
			{
				if(/($ip_regex)/)
				{
					$ip = $1;
					$ip_mapper{$ip} ++ if $ip !~ /\.255$/ && $ip !~ /\.0$/;
				}
			}
			
		}
		
		my @ip_list = sort {$a cmp $b} keys %ip_mapper;
		#stdout::debug("Main: \@ip_list = ".Dumper(\@ip_list));
		stdout::info("Main: Host Discovered: $_\n") foreach @ip_list;
		stdout::info("Main: Found ".($#ip_list+1)." ip addresses\n");
		
		return @ip_list;
	}
	#print "\n";
	
# 	foreach my $host (sort {$a cmp $b} keys %collation_map)
# 	{
# 		#print "Scanning $host...\n";
# 		my $iaddr = inet_aton($host); # or whatever address
# 		my $name  = gethostbyaddr($iaddr, AF_INET);
# 		my ($data) = NetMon::Classifier::classify($host);
# 		print "$host: \t $data->{type} ".($name ? "($name)" : ''). "\n"; #($host) score: $data->{score})\n";
# 	}
# 

	sub read_dns_config
	{
		my $subnet_manager = shift;
		
		# Check the DNS config for any IPs to use
		my $resolv_config = '/etc/resolv.conf';
		my @resolv = `cat $resolv_config`;
		foreach (@resolv)
		{
			next if !/($ip_regex)/;
			$subnet_manager->found_ip($1);
		}
		
		# Cheat here and add the resolv config data so that it gets read as another possible IP to discover
		NetMon::Discovery::ThreadManager->add_thread(undef,$resolv_config,'read_dns_config');
	}
	
	sub read_ifconfig
	{
		my $subnet_manager = shift;
		# Discover the subnet(s) available on active interfaces
		my @self_ip_data = `ifconfig | grep 'inet addr'`;
		# Win32 allowances
		if(!@self_ip_data)
		{
			@self_ip_data = grep {/IP Address/} `ipconfig`;
		}
		s/[\r\n]//g foreach @self_ip_data;
		
		foreach my $data (@self_ip_data)
		{
			# skip loopback data
			next if index($data,'127.0.0.1') > -1;
			
			my ($ip,$bcast,$netmask) = $data =~ /inet addr:($ip_regex)\s+bcast:($ip_regex)\s+mask:($ip_regex)/i;
		
			$subnet_manager->found_ip($ip,$bcast);
		}
	}
	
	sub read_arptable
	{
		my $subnet_manager = shift;
		# Read the ARP cache for any known hosts
		my $arp_cachefile = ".arp.thread";
		if(my $pid = fork)
		{
			stdout::debug("read_arptable(): Forked ARP Thread: $arp_cachefile\n");
			NetMon::Discovery::ThreadManager->add_thread($pid,$arp_cachefile,'read_arptable()'); # last str arg just for pretty debugging
		}
		else
		{
			system("arp -a | grep -v 'at <incomplete>' > $arp_cachefile");
			
			my @lines = `cat $arp_cachefile`;
			stdout::debug("read_arptable(): ARP Read: Read $#lines lines from $arp_cachefile\n");
			
			foreach(@lines)	
			{
				# event tho we're in another thread, the subnet manager correctly correlates the ip list (or SHOULD)
				$subnet_manager->found_ip($1) if /($ip_regex)/;
			}
			
			stdout::debug("read_arptable(): End ARP read\n");
			NetMon::Discovery::ThreadManager->exit_thread('read_arptable()'); #str arg just for pretty debugging
		}
	}
	
};
1;


=head1 BUGS

=over 12

=item Ignores subnet from ifconfig and assumes all IPs are Class C for quicker scanning

=back

=head1 ACKNOWLEDGEMENTS

=over 12

=item PerlMonk jwkrahn (Priest) - pointing out pod problems, not watching open return values, etc.

=back

=head1 COPYRIGHT

Undetermined yet. All I really ask is that you share any changes/updates/fixes/new ideas for this program with me and the 
PerlMonks community. Visit L<http://perlmonks.org/index.pl?node_id=747546> to share and care.

=head1 AVAILABILITY

L<http://perlmonks.org/index.pl?node_id=747546>

=head1 AUTHOR

Josiah Bryan, <josiahbryan@gmail.com>

=cut
