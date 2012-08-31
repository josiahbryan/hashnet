#!/usr/bin/perl
use strict;
use warnings;

package HashNet::StorageEngine::PeerDiscovery;
{
	use NetMon::Discovery;
	use Data::Dumper;
	use Time::HiRes qw/sleep alarm/;
	use Parallel::ForkManager;
	use IO::Socket;
	
	# Variable: $MAX_FORKS - The max number of forks to allow for the scanner
	our $MAX_FORKS    = 32;
	
# 	# Variable: $PING_TIMEOUT - Timeout for the pings before an ip is considered 'down'/offline/whatever
# 	our $PING_TIMEOUT =  0.75;
	
	# Variable: $PING_WAIT - The time to wait *between* pings - yield time, basically
	our $PING_WAIT    =  0.1;
	#stdout::debug("SubnetScanner: \$PING_TIMEOUT=$PING_TIMEOUT, \$MAX_FORKS=$MAX_FORKS\n");
	
	our $PEER_PORT = 8031;
	
	sub discover_peers
	{
		my @ip_list = NetMon::Discovery->ping_local_network();
		
		my $pm = Parallel::ForkManager->new($MAX_FORKS);
		
		my $cache = ".peerdiscovery.$$.thread";
		unlink($cache);
		
		@ip_list = sort {$a cmp $b} @ip_list;
		
		for my $ip (@ip_list)
		{
			$pm->start and next;
			
			if(my $ver_string = is_peer($ip))
			{
				# NetMon::Util from NetMon::Discovery
				NetMon::Util::lock_file($cache)   if $MAX_FORKS > 1;
				
				print "[INFO]  PeerDiscovery: ++ $ip: $ver_string\n";
				system("echo $ip >> $cache");
				
				NetMon::Util::unlock_file($cache) if $MAX_FORKS > 1;
			}
			
			sleep $PING_WAIT;
			$pm->finish;
		}
		
		$pm->wait_all_children;
		
		my @urls;
		
		my $ip_regex = $NetMon::Discovery::ip_regex;
		my @lines = `cat $cache`;
		my $ip;
		foreach(@lines)	
		{
			if(/($ip_regex)/)
			{
				$ip = $1;
				
				my $url = "http://$ip:$PEER_PORT/db";
				push @urls, $url;
				print "[INFO]  PeerDiscovery: Found peer: $url\n";
			}
		}
		
		unlink($cache) if -f $cache;
		
		if(!@urls)
		{
			die "[ERROR] PeerDiscovery: No peers found on local network";
		}
		
		#die Dumper \@urls;
		
		return @urls;
	}
	
	sub is_peer
	{
		shift if ref($_[0]) eq __PACKAGE__ or $_[0] eq __PACKAGE__;
		
		my $host = shift;
		my $port = shift || $PEER_PORT;
		my $path = '/db/ver';
		
		if($host =~ /^http:/)
		{
			my $url = $host;
			my $uri = URI->new($url)->canonical;
			$host = $uri->host;
			$port = $uri->port;
			$path = $uri->path;
			print STDERR "[DEBUG] PeerDiscovery: is_peer(): Parsed '$host', '$port', '$path' from '$url'\n";
		}
		
		# Error Status Codes: 0=ok, 1=error, 2=warn
		my $error = 0;
		my $error_text = '';
		my $error_event = '';
		
		my $remote = undef;
		
		my $timeout = 0.75; # Needs Timer::HiRes
		
		#print STDERR "[TRACE] is_peer(): host: $host\n";
		 
		eval 
		{
			local $SIG{ALRM} = sub { die "alarm\n" };       # NB \n required
			alarm $timeout;
			
			$remote = IO::Socket::INET->new(
				Proto    => "tcp",
				PeerAddr => $host,
				PeerPort => $port,
			);
		
			alarm 0;
		};
		die if $@ && $@ ne "alarm\n";       # propagate errors
		
		my $timed_out = $@ ? 1:0;
		
		my $buffer;
		
		if($timed_out)
		{
			$error = 1;
			$error_text = "Cannot open connection to ".$host.":".$port." - connect timed out";
			$error_event = 'PORT CONNECTION TIMEOUT';
			#warn "[ERROR] $error_text";
		}
		elsif(!$remote)
		{
			$error = 1;
			$error_text = "Cannot open connection to ".$host.":".$port.", even though SYN/ACK ping passed";
			$error_event = 'PORT CONNECTION ERROR';
			#warn "[ERROR] $error_text";
		}
		else
		{
			my $proto = 'http'; #lc $self->protocal;
			
			my $send;
			my $expect; 
			
# 			if($proto eq 'http')
# 			{
# 				$send = "GET ".$self->http_path_check." HTTP/1.0\r\nHost: ".$host."\r\n\r\n";
# 				$expect = $self->http_string_match;
# 			}
# 			else
# 			{
# 			
# 				$send = $self->port_send;
# 				$send =~ s/(0x.{2})/eval($1)/segi;
# 				$send =~ s/(\\r\\n)/\r\n/g;
# 				
# 				$expect = $self->port_expect;
# 				$expect =~ s/(0x.{2})/eval($1)/segi;
# 				
# 			}
			
			$send = "GET $path HTTP/1.0\r\nHost: ".$host."\r\n\r\n";
			$expect = 'HashNet';
			
			my $start_time = time;
			
			#print STDERR "Sending[$send]\n";
			print $remote $send ;
			
			# Wrap the read in an alarm timeout so that
			# remote processes can't hange the checks
			my @buffer;
			eval 
			{
				local $SIG{ALRM} = sub { die "alarm\n" };       # NB \n required
				alarm $timeout;
				push @buffer, $_ while $_ = <$remote>;
				alarm 0;
			};
			die if $@ && $@ ne "alarm\n";       # propagate errors
			my $timed_out = $@ ? 1:0;
			
			my $len = (time - $start_time) * 1000;
			$len = sprintf('%.06f',$len);
			
			if(!@buffer)
			{
				if($timed_out)
				{
					$error = 1;
					$error_text = "Timeout while waiting for respone from ".$proto." check ".$host.":".$port;
					warn "[ERROR] $error_text";
					$error_event = 'PROTOCAL TIMEOUT';
					
					#$self->get_builtin_sensor('port_read_time','ms')->log(undef,"$event: $text");
			
				}
				else
				{
					$error = 2;
					$error_text = "No data returned from $proto check on ".$host.":".$port;
					warn "[WARN] $error_text";
					$error_event  = 'EMPTY PROTOCAL RESPONSE';
					
					#$self->get_builtin_sensor('port_read_time','ms')->log($len);
			
				}
			}
			else
			{
				$buffer = join '', @buffer;
				
				#print STDERR "[TRACE] is_peer(): buffer: '$buffer'\n";
				
				#$buffer = trim_ansi_codes($buffer) if $proto eq 'telnet';
				
				if($buffer =~ /$expect/i)
				{
					$error = 0;
					$error_text = "Successfully found string '$expect' in data from ".$host.":".$port;
					$error_event = 'PORT CHECK SUCCEDED';
					
					#$self->get_builtin_sensor('port_read_time','ms')->log($len);
					#return 1; # is peer
				}
				else
				{
					$error = 1;
					$error_text = "Expected string '$expect' was not found in data returned from ".$host.":".$port;
					warn "[WARN] $error_text";
					$error_event  = 'PORT CHECK FAILED';
					
					#$self->get_builtin_sensor('port_read_time','ms')->log($len);
				}
				#print STDERR "Debug: check_string: '$check_str'\n";
				#print STDERR $buffer;
			}
			
		}
		
		if($remote) { eval {close($remote)}; undef $@; }
		
		if(!$error && $buffer =~ /Version (\d+(?:\.\d+)?)/)
		{
			return $1;
		}
		
		return $error <= 0;
	}


};
1;
