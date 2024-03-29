#!/usr/bin/perl
use strict;
use warnings;

# Patch 'Socket' module - on at least one of my devel systems, when using Net::Server::* as a 'net_server',
# the following error is output right when the connection starts and the process dies:
#	Bad arg length for Socket::unpack_sockaddr_in, length is 28, should be 16 at /usr/lib/perl5/5.8.8/i386-linux-thread-multi/Socket.pm line 370.
# By wrapping unpack_sockaddr_in(), I can trap the error and continue on.
# The code below in sockaddr_in() is a direct copy-paste from Socket.pm, with only the the eval{} and die() calls added.
package Socket;
{
	no warnings 'redefine'; # disable warning 'Subroutine sockaddr_in redefined at HashNet/StorageEngine/PeerServer.pm line ...'
	use Carp qw/croak/;
	
	sub sockaddr_in 
	{
		if (@_ == 6 && !wantarray) { # perl5.001m compat; use this && die
			my($af, $port, @quad) = @_;
			warnings::warn "6-ARG sockaddr_in call is deprecated"
			if warnings::enabled();
			pack_sockaddr_in($port, inet_aton(join('.', @quad)));
		} elsif (wantarray) {
			croak "usage:   (port,iaddr) = sockaddr_in(sin_sv)" unless @_ == 1;
			eval { unpack_sockaddr_in(@_); };
			die $@ if $@ && $@ !~ /Bad arg length for Socket::unpack_sockaddr_in/;
		} else {
			croak "usage:   sin_sv = sockaddr_in(port,iaddr))" unless @_ == 2;
			pack_sockaddr_in(@_);
		}
	}
};

# # Override the start() method of ::Brick so we can add ForkManager
# package HTTP::Server::Brick::ForkLimited;
# {
# 
# use base 'HTTP::Server::Brick';
# use Parallel::ForkManager;
# use HTTP::Status;
# 
# # NOTE: This code is copied straight from Brick.pm - we just added the ForkManager code
# 
# =head2 start
# 
# Actually starts the server - this will loop indefinately, or until
# the process recieves a C<HUP> signal in which case it will return after servicing
# any current request, or waiting for the next timeout (which defaults to 5s - see L</new>).
# 
# =cut
# 
# sub start {
#     my $self = shift;
#     my $max_forks = shift || 25;
#     
#     my $pm = $self->{fork} ? Parallel::ForkManager->new($max_forks) : undef;
# 
#     my $__server_should_run = 1;
# 
#     # HTTP::Daemon chokes on multiple simultaneous requests
#     unless ($self->{leave_sig_pipe_handler_alone}) {
#         $self->{_old_sig_pipe_handler} = $SIG{'PIPE'};
#         $SIG{'PIPE'} = 'IGNORE';
#     }
# 
#     $SIG{CHLD} = 'IGNORE' if $self->{fork};
# 
#     $self->{daemon} = $self->{daemon_class}->new(
#         ReuseAddr => 1,
#         LocalPort => $self->{port},
#         LocalHost => $self->{host},
#         Timeout => 5,
#         @{ $self->{daemon_args} },
#        ) or die "Can't start daemon: $!";
# 
#     # HTTP::Server::Daemon seems inconsistent in returning a string vs URI object
#     my $url_string = UNIVERSAL::can($self->{daemon}->url, 'as_string') ?
#       $self->{daemon}->url->as_string :
#         $self->{daemon}->url;
# 
#     $self->_log(error => "Server started on $url_string");
# 
#     while ($__server_should_run) {
#         my $conn = $self->{daemon}->accept or next;
# 
#         # if we're a forking server, fork. The parent will wait for the next request.
#         # TODO: limit number of children
#         #next if $self->{fork} and fork;
#         next if $self->{fork} and $pm->start;
#         while (my $req = $conn->get_request) {
# 
#           # Provide an X-Brick-Remote-IP header
#           my ($r_port, $r_iaddr) = Socket::unpack_sockaddr_in($conn->peername);
#           my $ip = Socket::inet_ntoa($r_iaddr);
#           $req->headers->remove_header('X-Brick-Remote-IP');
#           $req->header('X-Brick-Remote-IP' => $ip) if defined $ip;
# 
#           my ($submap, $match) = $self->_map_request($req);
# 
#           if ($submap) {
#               if (exists $submap->{path}) {
#                   $self->_handle_static_request( $conn, $req, $submap, $match);
# 
#               } elsif (exists $submap->{handler}) {
#                   $self->_handle_dynamic_request( $conn, $req, $submap, $match);
# 
#               } else {
#                   $self->_send_error($conn, $req, RC_INTERNAL_SERVER_ERROR, 'Corrupt Site Map');
#               }
# 
#           } else {
#               $self->_send_error($conn, $req, RC_NOT_FOUND, ' Not Found in Site Map');
#           }
#         }
# 
#         HashNet::Util::Logging::losgmsg('TRACE',"[HTTP Request End]\n\n");
# 
#         $pm->finish if $self->{fork}; # TODO: I assume this exits so the next exit is unecessary ...
#         # should use a guard object here to protect against early exit leaving zombies
#         exit if $self->{fork};
#     }
# 
#     $pm->wait_all_children if $self->{fork};
# 
#     unless ($self->{leave_sig_pipe_handler_alone}) {
#         $SIG{'PIPE'} = $self->{_old_sig_pipe_handler};
#     }
# 
#     1;
# }
# 
# };

package HTTP::Server::Brick::PeerServerBase;
{

use base 'HTTP::Server::Brick';
use Parallel::ForkManager;
use HTTP::Status;

# NOTE: This code is copied straight from Brick.pm - we just added the 'refresh peers' call and the $conn hook

=head2 start

Actually starts the server - this will loop indefinately, or until
the process recieves a C<HUP> signal in which case it will return after servicing
any current request, or waiting for the next timeout (which defaults to 5s - see L</new>).

=cut
sub start {
    my $self = shift;


    $HTTP::Server::Brick::__server_should_run = 1;

    # HTTP::Daemon chokes on multiple simultaneous requests
    unless ($self->{leave_sig_pipe_handler_alone}) {
        $self->{_old_sig_pipe_handler} = $SIG{'PIPE'};
        $SIG{'PIPE'} = 'IGNORE';
    }

    $SIG{CHLD} = 'IGNORE' if $self->{fork};

    $self->{daemon} = $self->{daemon_class}->new(
        ReuseAddr => 1,
        LocalPort => $self->{port},
        LocalHost => $self->{host},
        Timeout => 5,
        @{ $self->{daemon_args} },
       ) or die "Can't start daemon: $!";

    # HTTP::Server::Daemon seems inconsistent in returning a string vs URI object
    my $url_string = UNIVERSAL::can($self->{daemon}->url, 'as_string') ?
      $self->{daemon}->url->as_string :
        $self->{daemon}->url;

    $self->_log(error => "Server started on $url_string");

    my $peer_server = $self->{peer_server};

    while ($HTTP::Server::Brick::__server_should_run) {
        my $conn = $self->{daemon}->accept or next;

        # if we're a forking server, fork. The parent will wait for the next request.
        # TODO: limit number of children
        next if $self->{fork} and fork;

        $peer_server->{in_fork} = 1;

        #$self->{current_conn} = $conn;
        #$self->_log(error => "Current connection '$conn'");

        while (my $req = $conn->get_request) {

          $peer_server->engine->refresh_peers;
          $peer_server->{current_conn} = $conn;

          # Provide an X-Brick-Remote-IP header
          my ($r_port, $r_iaddr) = Socket::unpack_sockaddr_in($conn->peername);
          my $ip = Socket::inet_ntoa($r_iaddr);
          $req->headers->remove_header('X-Brick-Remote-IP');
          $req->header('X-Brick-Remote-IP' => $ip) if defined $ip;

          $ENV{REMOTE_ADDR} = $ip;

          my ($submap, $match) = $self->_map_request($req);

          if ($submap) {
              if (exists $submap->{path}) {
                  $self->_handle_static_request( $conn, $req, $submap, $match);

              } elsif (exists $submap->{handler}) {
                  $self->_handle_dynamic_request( $conn, $req, $submap, $match);

              } else {
                  $self->_send_error($conn, $req, RC_INTERNAL_SERVER_ERROR, 'Corrupt Site Map');
              }

          } else {
              $self->_send_error($conn, $req, RC_NOT_FOUND, ' Not Found in Site Map');
          }
        }
        # should use a guard object here to protect against early exit leaving zombies
        exit if $self->{fork};
    }


    unless ($self->{leave_sig_pipe_handler_alone}) {
        $SIG{'PIPE'} = $self->{_old_sig_pipe_handler};
    }

    1;
}


sub _log {
	my ($self, $log_key, $text) = @_;
	
	#print STDERR " =======> $log_key <==========\n";
	
	$log_key = $log_key eq 'access' ? 'INFO' :
		   $log_key eq 'error'  ? 'ERROR' :
		   'DEBUG';

	$log_key = 'INFO' if $text =~ /^Server started/;
	
	HashNet::Util::Logging::logmsg($log_key, "PeerServerBase: $text\n");
	
	
	
	#$self->{"${log_key}_log"}->print( '[' . localtime() . "] [$$] ", $text, "\n" )
		;# if $text =~ /^\//;
		# if $text =~ /^\//;
}




};

package HashNet::StorageEngine::PeerServer;
{
# 	use HTTP::Server::Simple::CGI;
# 	use base qw(HTTP::Server::Simple::CGI);
	
# 	use AnyEvent::HTTPD;
	use AnyEvent::HTTP;

	use HTTP::Server::Brick;
	
	use HashNet::StorageEngine;
	use HashNet::Util::Logging;
	
	use Storable qw/lock_nstore lock_retrieve freeze thaw/;
	use LWP::Simple qw/getstore/;
	use Data::Dumper;
	use URI::Escape;
	use URI; # to parse URLs given to is_this_peer
	#use Socket; # for gethostbyname() in 3_peer
	use JSON::PP qw/encode_json decode_json/;
	use Socket; # for inet_ntoa et al
	use YAML::Tiny; # for load_config/save_config
	use UUID::Generator::PurePerl; # for node_info
	use Geo::IP; # for Geolocating our WAN address
	use HTTP::Request::Params; # for http_respond
	use Cwd qw/abs_path/; # for images, etc
	use DBM::Deep; # for our has_seen_tr()/etc routines
	# Explicitly include here for the sake of buildpacked.pl
	use DBM::Deep::Engine::File;
	#use HTML::Template; # for use in the visulization
	use LWP::MediaTypes qw(guess_media_type); # for serving files
	use Net::Ping; # for pinging hosts in resp_reg_peer
	use MIME::Base64::Perl; # for encoding/decoding binary data in the htmlify routine
	use File::Touch; # for touching testing_flag_file
	
	our $PING_TIMEOUT =  1.75;
	
	my $pinger = Net::Ping->new('tcp');
	$pinger->hires(1);
	

	

	our @Startup_ARGV = (); # set by dengpeersrv.pl - used in request_restart();
	
	our %HTTP_FILE_RESOURCES = (
			
		'/favicon.ico'		=> 'www/images/favicon.ico',
		'/hashnet-logo.png'	=> 'www/images/hashnet-logo.png',
		'/basicstyles.css'	=> 'www/css/basicstyles.css',
		
		'/db/viz'		=> 'www/viz.html',
		'/images/circle.png'	=> 'www/images/circle.png',
		
		'/js/jquery.jsPlumb-1.3.13-all-min.js'	=> 'www/js/jquery.jsPlumb-1.3.13-all-min.js',
		'/js/jquery.jsPlumb-1.3.13-all.js'	=> 'www/js/jquery.jsPlumb-1.3.13-all.js',
	);

	#sub peer_url  { 'http://localhost:' . peer_port() . '/db' }
	
	my @IP_LIST_CACHE;
	sub my_ip_list
	{
		return @IP_LIST_CACHE if @IP_LIST_CACHE;
	
		# Based on code from http://www.perlmonks.org/?node_id=53660
		my $interface;
		my %ifs;
			
		foreach ( qx{ (LC_ALL=C /sbin/ifconfig -a 2>&1) } ) 
		{
			$interface = $1 if /^(\S+?):?\s/;
			next unless defined $interface;
			$ifs{$interface}->{state} = uc($1) if /\b(up|down)\b/i;
			# NOTE Yes, I know - need to find a way to make compat with IPv6
			$ifs{$interface}->{ip}    = $1     if /inet\D+(\d+\.\d+\.\d+\.\d+)/i;
		}

		# Skip bridges because even though they are not technically the localhost interface,
		# if we have the same bridge ip on multiple machines (such as two machines that have
		# xen dom0 or VirtualBox installed), resp_reg_ip would change the bridgeip to localhost
		# since the same ip appears in both lists. (See resp_reg_ip())
		unless(`which brctl 2>&1` =~ /no brctl/)
		{
			foreach ( qx{ brctl show } )
			{
				$interface = $1 if /^(\S+?)\s/;
				next unless defined $interface && $interface ne 'bridge'; # first line is 'bridge name ...';
				delete $ifs{$interface};
			}
		}
		
		@IP_LIST_CACHE = ();
		foreach my $if (keys %ifs)
		{
			next if !defined $ifs{$if} || $ifs{$if}->{state} ne 'UP';
			my $ip = $ifs{$if}->{ip} || '';
			
			push @IP_LIST_CACHE, $ip if $ip;
		}
		
		return grep { $_ ne '127.0.0.1' } @IP_LIST_CACHE;
	}
	
	
	sub is_this_peer
	{
		my $class = shift;
		my $url = shift;
		my $uri  = URI->new($url)->canonical;
		return 0 if !$uri->can('host');
		
		my $host = $uri->host;
		$host = '127.0.0.1' if $host eq 'localhost';
		
		# Multiple servers can be run on same machine, just different ports
		return 0 if $uri->port != peer_port();
		
		# Even if they are using a different hostname for local host,
		# they will be flaged it as the local peer if the ports match
		return 1 if ($host eq '127.0.0.1' ||
		             inet_ntoa(inet_aton($host))
		                   eq '127.0.0.1');
		
		#logmsg "DEBUG", "is_this_peer: url: $url\n";
		#logmsg "DEBUG", "is_this_peer: host:$host, host:$host\n";
		
		# Check all our addresses to see if the $url matches any of our IPs
		my @ip_list = my_ip_list();
		foreach my $ip (@ip_list)
		{
			return 1 if $ip eq $host;
		}
		
		#logmsg "DEBUG", "is_this_peer: $url is not this peer.\n";
		return 0;
	}

	sub is_this_host
	{
		#my $class = shift;
		my $url = shift;
		my $uri  = URI->new($url)->canonical;
		#debug "PeerServer: is_this_host('$url'): \$uri->can('host'): ", ($uri->can('host') ? 1:0), "\n";
		return 0 if !$uri->can('host');

		my $host = $uri->host;
		#debug "PeerServer: is_this_host('$url'): \$host='$host'\n";

		# Even if they are using a different hostname for local host,
		# they will be flaged it as the local peer if the ports match
		return 1 if ($host eq '127.0.0.1' || $host eq 'localhost');

		# Check all our addresses to see if the $url matches any of our IPs
		my @ip_list = my_ip_list();
		#debug "PeerServer: is_this_host('$url'): \@ip_list=(",join('|',@ip_list),")\n";
		foreach my $ip (@ip_list)
		{
			#debug "PeerServer: is_this_host('$url'): \t testing $ip == $host\n";
			return 1 if $ip eq $host;
		}

		#debug "PeerServer: is_this_host('$url'): no match, returning 0\n";
		return 0;
	}

	my HashNet::StorageEngine::PeerServer $ActivePeerServer = undef;
	sub active_server { $ActivePeerServer }
	
	our $DEFAULT_PORT = 8031;
	
	sub peer_port
	{
		if($ActivePeerServer)
		{
			return $ActivePeerServer->{port} || $DEFAULT_PORT;
		}
		else
		{
			return $DEFAULT_PORT;
		}
	}
	
	# NOTE not used anymore
	#sub net_server { 'Net::Server::PreFork' }
	
	sub reg_peer
	{
		my $self = shift;
		my $peer = shift;
		
		my $url = $peer->url . '/reg_peer';

# 		if($peer->host_down)
# 		{
# 			logmsg "TRACE", "PeerServer: reg_peer(): Not registering with peer at $url, host marked as down\n";
# 			return;
# 		}
# 		
		if($self->is_this_peer($url))
		{
			logmsg "TRACE", "PeerServer: reg_peer(): Not registering with peer at $url, same as this host\n";
			return;
		}

		# Lock peer and read in state if changed in another thread
		my $locker = $peer->update_begin;
		# $locker will call update_end when it goes out of scope

		my $other_peer_port = URI->new($url)->port;

		my $allow_localhost = $self->peer_port() != $other_peer_port ? 1:0;
		#logmsg "DEBUG", "PeerServer: self->peer_port:", $self->peer_port(),", other_peer_port:$other_peer_port, \$allow_localhost:$allow_localhost \n";

		# TODO - We use $other_peer_port here instead of $self->peer_port() BECAUSE we ASSUME that if the other peer is not using the
		# default peer port (our peer port), they are running over an SSH tunnel - and we ASSUME the SSH tunnel was set up with the same
		# port fowarded on either side. *ASSUMPTIONS*
		# TODO - Updated assumption - if *our port* is not the default port, then use OUR PORT when registering since we ASSUME we are testing on a non-normal port
		my @discovery_urls = map { 'http://'.$_.':'.($self->peer_port() != $DEFAULT_PORT ? $self->peer_port() : $other_peer_port).'/db' } grep { $allow_localhost ? 1 : $_ ne '127.0.0.1' } my_ip_list();
		
		#@discovery_urls = ($peer->{known_as}) if $peer->{known_as};
		
		my $payload = "peer_url=" . uri_escape(join('|', @discovery_urls)) . "&ver=$HashNet::StorageEngine::VERSION&uuid=".$self->node_info->{uuid};
		#my $payload_encrypted = $payload; #HashNet::Cipher->cipher->encrypt($payload);
		
		# LWP::Simple
		my $final_url = $url . '?' . $payload;
		logmsg "TRACE", "PeerServer: reg_peer(): Trying to register as a peer at url: $final_url\n";
		#die "Test over";

		my $r;
		HashNet::StorageEngine::Peer::exec_timeout(10.0, sub
		{
			$r = LWP::Simple::get($final_url);
			$r = '' if !defined $r;
		});

		if($r eq '')
		{
			logmsg "TRACE", "PeerServer: reg_peer(): No valid response when trying to register with peer at $url, marking as host_down\n";
			$peer->{host_down} = 1;
		}
		elsif(!$r)
		{
			$peer->{poll_only} = 1;
			logmsg "TRACE", "PeerServer: reg_peer(): Peer $url cannot reach me to push transactions, I must pull from it (flagging as pull-only.)\n";
		}
		else
		{
			$r =~ s/[\r\n]$//g;
			$peer->{known_as} = $r =~ /http:/ ? $r : '';
			logmsg "TRACE", "PeerServer: reg_peer(): \t + Registered with $url", ($peer->{known_as} ? " as: $peer->{known_as}" : ""), "\n";
		}
		
		# Write out the peer state and unlock
		$peer->update_end;
		# When $locker goes out of scope, it should call update_end automatically - but call it anyway to be safe
		
		# Check against the peer to see if they have newer software than we have
		#$self->update_software($peer);
		
	}

	sub update_software
	{
		my $self = shift;
		my $peer = shift;

		if($peer->host_down)
		{
			logmsg "TRACE", "PeerServer: update_software(): Not checking version with peer at $peer->{url}, host marked as down\n";
			return;
		}

		if($self->is_this_peer($peer->url))
		{
			logmsg "TRACE", "PeerServer: update_software(): Not checking version with peer at $peer->{url}, same as this host\n";
			return;
		}

		my $ver = $HashNet::StorageEngine::VERSION;
		my $url = $peer->url . '/ver?upgrade_check=' . $ver . '&peer_url=' . ($peer->{known_as} || '');

		#logmsg "TRACE", "PeerServer: update_software(): Calling url '$url'\n";
		my $json = '';
		HashNet::StorageEngine::Peer::exec_timeout(10.0, sub
		{
			$json = LWP::Simple::get($url);
		});

		#logmsg "TRACE", "PeerServer: update_software(): Got json: $json\n";
		
		$json ||= '';
		if(!$json)
		{
			# TODO Should we mark host as down?
			logmsg "TRACE", "PeerServer: update_software(): No valid version data from $peer->{url}\n";
			return;
		}

		#use Data::Dumper;
		#print Dumper \@_;

		my $data;
		{
			local $@;
			eval
			{
				$data = decode_json($json);
			};

			if($@)
			{
				logmsg "TRACE", "PeerServer: update_software(): Error parsing data from $peer->{url}: $@, data: $json\n";
				return;
			}
		}

		if($data->{version} > $ver &&
		   $data->{has_bin})
		{
			#return $data->{version};
			logmsg "TRACE", "PeerServer: update_software(): Updated version '$ver' available, downloading from peer...\n";
			$self->download_upgrade($peer);
		}
		else
		{
			logmsg "TRACE", "PeerServer: update_software(): Running same or newer version as peer $peer->{url} ($ver >= $data->{version}) (or !{has_bin} [$data->{has_bin}])\n";
		}

		return;
	}

	sub download_upgrade
	{
		my $self = shift;
		my $peer = shift;

		my $upgrade_url = $peer->url . '/bin_file';

		if($peer->host_down)
		{
			logmsg "TRACE", "PeerServer: download_upgrade(): Not download upgrade from peer at $upgrade_url, host marked as down\n";
			return;
		}
		
		if($self->is_this_peer($peer->url))
		{
			logmsg "TRACE", "PeerServer: download_upgrade(): Not download upgrade from peer at $upgrade_url, same as this host\n";
			return;
		}

		my $bin_file = $self->bin_file;
		if(!$bin_file)
		{
			logmsg "TRACE", "PeerServer: download_upgrade(): Cannot download upgrade from $upgrade_url - no bin_file set.\n";
			return;
		}

		logmsg "INFO", "PeerServer: download_upgrade(): Downloading update from $upgrade_url to $bin_file\n";

		getstore($upgrade_url, $bin_file);

		logmsg "INFO", "PeerServer: download_upgrade(): Download finished.\n";

		$self->request_restart;
	}
	
	sub kill_children
	{
		my $self = shift;
		
		my $peer_port = $self->peer_port();
# 		print "#######################\n";
# 		system("lsof -i :$peer_port");
# 		print "#######################\n";
# 		print "$0\n";
# 		print "#######################\n";
		
		foreach ( qx{ lsof -i :$peer_port | grep -P '(perl|$0)' } )
		{
			my ($pid) = (split /\s+/)[1];
			next if $pid eq 'PID' || $pid eq $$;  # first line of lsof has the header PID, etc
			
			# Grab the process description just for debugging/info purposes
			my @lines = split /\n/, `ps $pid`;
			shift @lines;
			
			if(@lines)
			{
				logmsg "INFO", "PeerServer: kill_children(): Killing child: $pid\n";
				logmsg "INFO", "            $lines[0]\n";
				
				# Actually kill the process
				kill 15, $pid;
			}
		}

		if($self->{timer_loop_pid})
		{
			logmsg "INFO", "PeerServer: kill_children(): Killing timer loop $self->{timer_loop_pid}\n";
			kill 15, $self->{timer_loop_pid};
		}
	}
	
	sub request_restart
	{
		my $self = shift;
		
		# Tell the buildpacked.pl-created wrapper NOT to remove the payload directory.
		# I've seen it happen /sometimes/ when we kill the child, a race condition develops,
		# where the rm -rf in the buildpacked.pl stub is still removing the folder while the
		# new binary is decompressing the updated payload - resulting in a partial or 
		# corrupted payload and causing the new binary not to start up correctly, if at all.
		# So, we tell the stub to skip the 'rm -rf' after program exit and the new binary
		# will just overwrite the payload in place.
		$ENV{NO_CLEANUP} = 'true';
		
		# attempt restart
		logmsg "INFO", "PeerServer: request_restart(): Restarting server\n";
		
		$self->kill_children();

		logmsg "INFO", "PeerServer: request_restart(): All children killed, killing self: $$\n";

		if(fork)
		{
			# Kill the parent in a fork after one second
			# so the child has time to execute the system() command
			#sleep 1;
			kill 15, $$; # 15 = SIGTERM
			#system("kill $$");
		}
		else
		{
			# Close the app output so init messages from restarting (below) don't leak to any possible active HTTP requests
			#select(STDOUT);
			#close(STDOUT);
			
# 			#print STDERR "\$^X: $^X, \$0: $0, \@ARGV: @ARGV [END]\n";
# 			if($ENV{SCRIPT_FILE})
# 			{
# 				# running as a buildpacked.pl-packed file
# 				system("$0 &");
# 			}
# 			else
# 			{
				# Running as a regular script
				my $app = $0;
				$app =~ s/#.*$//g; # remove any comments from the app name
				my $cmd = "$^X $app @Startup_ARGV &";
				
				logmsg "INFO", "PeerServer: request_restart(): In monitor fork $$, executing restart command: '$cmd'\n";
				system($cmd);
#			}
			exit;
		}
	}
	
	sub http_respond
	{
		my ($res, $ctype, $content) = @_;
		$res->add_content($content);
		$res->header('Content-Type', $ctype);
		return 1;
	}
	
	sub http_param
	{
		my ($req, $key) = @_;
		my $parser = $req->{_params_parser} || HTTP::Request::Params->new({ req => $req });
		$req->{_params_parser} ||= $parser;
		return $parser->params->{$key};
	}
	
	sub set_repeat_timeout($$)
	{
		my ($time, $code_sub) = @_;
		my $timer_ref;
		my $wrapper_sub; $wrapper_sub = sub {
			
			$code_sub->();
			
			undef $timer_ref;
			# Yes, I know AE has an 'interval' property - but it does not seem to work,
			# or at least I couldn't get it working. This does work though.
			$timer_ref = AnyEvent->timer (after => $time, cb => $wrapper_sub);
		};
		
		# Initial call starts the timer
		#$wrapper_sub->();
		
		# Sometimes doesn't work...
		$timer_ref = AnyEvent->timer (after => $time, cb => $wrapper_sub);
		
		return $code_sub;
	};
	
	sub set_timeout($$)
	{
		my ($time, $code_sub) = @_;
		my $timer_ref;
		my $wrapper_sub; $wrapper_sub = sub {
			
			$code_sub->();
			
			undef $timer_ref;
			undef $wrapper_sub;
		};
		
		$timer_ref = AnyEvent->timer (after => $time, cb => $wrapper_sub);
		
		return $code_sub;
	}
	

	our $CONFIG_FILE= ['/etc/dengpeersrv.cfg','/root/dengpeersrv.cfg','/opt/hashnet/datasrv/dengpeersrv.cfg'];

	sub new
	{
		my $class  = shift;
		my $engine;
		my $port     = $DEFAULT_PORT;
		my $bin_file = '';
		my $testing_flag_file = undef;
		
		my %opts;
		if(@_ == 1)
		{
			$engine = shift;
		}
		else
		{
			%opts = @_;
			$engine = $opts{engine};
			$port   = $opts{port} || $port;
			$bin_file = $opts{bin_file} || '';
			$CONFIG_FILE = $opts{config} if $opts{config};
			$testing_flag_file = $opts{testing_flag_file};
		}
		
		#my $self = $class->SUPER::new(peer_port());
		my $self = bless {}, $class;
		$ActivePeerServer = $self;
		
		if($port != $DEFAULT_PORT)
		{
			$HashNet::Util::Logging::CUSTOM_OUTPUT_PREFIX = "[:${port}] ";
		}

		$self->{testing_flag_file} = $testing_flag_file;

		
		#my $httpd = AnyEvent::HTTPD->new(port => $port);
		
# 		my $hostname = `hostname`;
# 		$hostname =~ s/[\r\n]//g;
		
		my %server_args = (
			port => $port,
			#host => $hostname,
			#error_log => \*STDOUT, # default
			fork => 1,
		);
	
		#my $httpd = HTTP::Server::Brick::ForkLimited->new( %server_args );
		my $httpd = HTTP::Server::Brick::PeerServerBase->new( %server_args );
		$httpd->{peer_server} = $self;
		
		$self->{httpd}  = $httpd;
		$self->{engine} = $engine;
		$self->{port}   = $port;

		$self->{bin_file} = $bin_file;
		#logmsg "DEBUG", "Server 'bin_file': $bin_file, test retrieve: ", $self->bin_file, "\n";

		my $db_root = $self->engine->db_root;

		$self->{node_info_changed_flag_file} = $db_root . '.node_info_changed_flag';
		logmsg "TRACE", "PeerServer: Node info changed flag file is $self->{node_info_changed_flag_file}\n";

		$self->{tr_cache_file} = $db_root . '.tr_flags';
		#$self->{tr_cache_file} = "/tmp/test".$self->peer_port.".db";
		#$self->{tr_cache_file} = $db_root."test".$self->peer_port.".db";
		#$self->tr_flag_db->put(test => time());
		logmsg "TRACE", "PeerServer: Using transaction flag file $self->{tr_cache_file}\n";
		#logmsg "DEBUG", "Test retrieve: ",$self->tr_flag_db->get('test'),"\n";


		$self->load_config;
		$self->save_config; # re-push into cloud

		
		# Fork off a event loop to fire off timed events
		if(my $pid = fork)
		{
			trace "PeerServer: Forked timer loop as pid $pid\n";
			$self->{timer_loop_pid} = $pid; # for use in request_restart()
		}
		else
		{
			$0 = "$0 # timer loop";
			use AnyEvent;
			use AnyEvent::Impl::Perl; # explicitly include this so it's included when we buildpacked.pl
			use AnyEvent::Loop;

			# Register with peers *after* the event loop starts
			# so that if we do have to upgrade, $self->bin_file
			# is set so we know where to store the software
			
			# NOTE DisabledForTesting
			set_timeout         0.5, sub
			{
				logmsg "INFO", "PeerServer: Registering with peers\n";
				my @peers = @{ $engine->peers };
				foreach my $peer (@peers)
				{
					# Try to register as a peer (locks state file automatically)
					$self->reg_peer($peer);
				}
				logmsg "INFO", "PeerServer: Registration complete\n\n";

				# tests/propogate.t (and perhaps others) need to wait till we've registered
				# with peers to continue testing
				if($self->{testing_flag_file})
				{
					touch($self->{testing_flag_file});
				}
			};

			set_repeat_timeout  1.0, sub
			{
				#logmsg "TRACE", "PeerServer: Pushing any transactions to push peers\n";
				
				my @peers = @{ $engine->peers };
				foreach my $peer (@peers)
				{
					$peer->load_changes();

					$self->push_needed($peer)
						if !$peer->poll_only &&
						   !$peer->host_down &&
						   !$self->is_this_peer($peer->url);
				}

				#logmsg "TRACE", "PeerServer: Push complete\n\n";
			};
			
			# NOTE DisabledForTesting
			set_repeat_timeout  15.0, sub
			{
				#logmsg "TRACE", "PeerServer: Pulling from poll-only peers\n";
				
				my @peers = @{ $engine->peers };
				foreach my $peer (@peers)
				{
					$peer->load_changes();
					
					$peer->poll()
						if ($peer->poll_only ||
						    $peer->host_down ) &&
						   !$self->is_this_peer($peer->url);
				}
				
				#logmsg "TRACE", "PeerServer: Pulling complete\n\n";
			};
			
			# Every 15 minutes, update time via SNTP
			set_repeat_timeout 60.0 * 15.0, sub
			{
				$engine->update_time_offset();
			};
			
			# NOTE DisabledForTesting
			my $check_sub = set_repeat_timeout 60.0, sub
			#my $check_sub = set_repeat_timeout 1.0, sub
			#my $check_sub = sub
			{
				logmsg "INFO", "PeerServer: Checking status of peers\n";

				my @peers = @{ $engine->peers };
				#@peers = (); # TODO JUST FOR DEBUGGING

				$self->engine->begin_batch_update();

				foreach my $peer (@peers)
				{
					$peer->load_changes();

					#logmsg "DEBUG", "PeerServer: Peer check: $peer->{url}: Locked, checking ...\n";

					# Make sure the peer is online, check latency, etc

					# NOTE DisabledForTesting
					$peer->update_distance_metric();

					# Polling moved above
					#$peer->poll();

					# NOTE DisabledForTesting
					$peer->put_peer_stats(); #$engine);

					# NOTE DisabledForTesting
					# Do the update after pushing off any pending transactions so nothing gets 'stuck' here by a failed update
					#logmsg "INFO", "PeerServer: Peer check: $peer->{url} - checking software versions.\n";
					$self->update_software($peer);
					#logmsg "INFO", "PeerServer: Peer check: $peer->{url} - version check done.\n";
				}

				# NOTE DisabledForTesting
				{
					my $inf  = $self->{node_info};
					my $uuid = $inf->{uuid};
					my $key_path = '/global/nodes/'. $uuid;

					if(-f $self->{node_info_changed_flag_file})
					{
						unlink $self->{node_info_changed_flag_file};
						#logmsg "DEBUG", "PeerServer: key_path: '$key_path'\n";
						foreach my $key (keys %$inf)
						{
							my $put_key = $key_path . '/' . $key;
							my $val = $inf->{$key};
							#logmsg "DEBUG", "PeerServer: Putting '$put_key' => '$val'\n";
							$self->engine->put($put_key, $val);
						}
					}

					my $db = $engine->tx_db;
					my $cur_tx_id = $db->length() -1;

					$self->engine->put("$key_path/cur_tx_id", $cur_tx_id)
						if ($self->engine->get("$key_path/cur_tx_id")||0) != ($cur_tx_id||0);
				}

				$self->engine->end_batch_update();

				logmsg "INFO", "PeerServer: Peer check complete\n\n";
			};

			$check_sub->();
			
			logmsg "TRACE", "PeerServer: Starting timer event loop...\n";

			# run the event loop, (should) never return
			AnyEvent::Loop::run();
			
			# we're in a fork, so exit
			exit(0);
		};

		# Setup 'locks' around requests so we can guard various parts of our code while in the middle of processing a request
# 		$httpd->reg_cb(
# 			client_connected => sub {
# 				my ($httpd, $host, $port) = @_;
# 				#logmsg "TRACE", "PeerServer: Client connected from $host\n";
# 				#print Dumper \@_;
# 				$self->{in_request} = 1;
# 			},
# 			client_disconnected => sub {
# 				my ($httpd, $host, $port) = @_;
# 				#logmsg "TRACE", "PeerServer: Client disconnected from $host\n";
# 				$self->{in_request} = 0;
# 			}
# 		);

		
		# Setup the default page
		#$httpd->reg_cb('' => sub
		my $root = $ENV{PACKED_ROOT} ? $ENV{PACKED_ROOT} : '';
		
		sub http_send_file
		{
			my $file = shift;
			return sub
			{
				my ($req, $res) = @_;
				my @buffer;
				open(F,"<$file") || die "Cannot read $file: $!";
				push @buffer, $_ while $_ = <F>;
				close(F);
				my $data = join '', @buffer;
				#my $ctype = `file -i $file`;
				#$ctype =~ s/^$file:\s*//g;
				#$ctype =~ s/[\r\n]//g;
				my $ctype = guess_media_type($file);
				#logmsg "TRACE", "PeerServer: Serving ", length($data)," bytes from $file as $ctype\n";
				http_respond($res, $ctype, $data);
			};
		}
		
		foreach my $key (keys %HTTP_FILE_RESOURCES)
		{
			my $abs_file = abs_path($root.$HTTP_FILE_RESOURCES{$key});
			#info "Registering $abs_file as path '$key'\n";
			$httpd->mount($key => { handler => http_send_file($abs_file) });
		};
		
		
		
# 		$httpd->mount( '/favicon.ico'      => { handler => http_send_file($favicon) } );
# 		$httpd->mount( '/hashnet-logo.png' => { handler => http_send_file($logo) } );
# 		$httpd->mount( '/basicstyles.css'  => { handler => http_send_file($styles) } );
# 		
		$httpd->mount('/' => { handler => sub
		{
			#my ($req, $res) = @_;
			my ($req, $res) = @_;
			
			#$req->respond ({ content => [ 'text/html',
			http_respond($res, 'text/html', 
				"<html>"
				. "<head><title>HashNet StorageEngine Server</title></head>"
				. "<link rel='stylesheet' type='text/css' href='/basicstyles.css' />"
				. "<body><h1><a href='/'><img src='/hashnet-logo.png' border=0 align='absmiddle'></a> HashNet StorageEngine Server</h1>"
				. "<ul>"
				. "<li><a href='/db/peers'>Peers</a>"
				. "<li><a href='/db/search'>Search</a>"
				. "<li><a href='/db/viz'>Visualize</a>"
				. "</ul>"
				. "<hr/>"
				. "<p><font size=-1><i>HashNet StorageEngine, Version <b>$HashNet::StorageEngine::VERSION</b>, date <b>". `date`. "</b></i></p>"
				#. "<script>setTimeout(function(){window.location.reload()}, 1000)</script>"
				. "</body></html>"
			);
		}});
		
		$httpd->mount('/db' => { handler => sub
		{
			my ($req, $res) = @_;
			$res->code(302);
			$res->header('Location', '/');
			$res->{target_uri} = URI::http->new('/');
			return $res;
		}});
		
		$httpd->mount('/db/viz/nodeinfo.js' => { handler => sub
		{
			my ($req, $res) = @_;
			
			my $list = $self->engine->list('/global/nodes');
			my $tree = searchlist_to_tree($list);
			my $out = build_nodeinfo_json($tree);
			
			# Add in any stored positions
			foreach my $node (@{$out || []})
			{
				my $data = $self->engine->get("/db/viz/state/node_pos/".$node->{uuid});
				next if !$data;
				
				my ($x,$y) = split /,\s*/, $data;
				$node->{x} = $x;
				$node->{y} = $y;
			}
			
			http_respond($res, 'text/javascript', encode_json($out));
		}});
		
		$httpd->mount('/db/viz/store_pos' => { handler => sub
		{
			my ($req, $res) = @_;
			
			my $uuid = http_param($req, 'uuid');
			my $x = http_param($req, 'x');
			my $y = http_param($req, 'y');
			
			$self->engine->put("/db/viz/state/node_pos/$uuid", "$x, $y");
			
			http_respond($res, 'text/plain', "OK");
		}});
		

		#$httpd->reg_cb('/db/search' => sub
		$httpd->mount('/db/search' => { handler => sub
		{
			my ($req, $res) = @_;

			my $path = http_param($req, 'path') || '/';
			
			sub stylize_key
			{
				my $key  = shift;
				my $path = shift || '';
				my @parts = split /\//, $key;
				shift @parts;  # first part always empty
				my $count = 0;
				my @html = map { s/($path)/<b>$1<\/b>/g if $path; '<span class=' . (++$count % 2 == 0 ? 'odd' : 'even').'>'.$_.'</span>' } @parts;
				return '<span class=key>/'.join('/',@html).'</span>';
				
			}
			
			my $list = $self->engine->list($path, 1); # 1 = include meta
			
			my $output = http_param($req, 'output') || 'html';
			if($output eq 'json')
			{
				http_respond($res, 'text/plain', encode_json(searchlist_to_tree($list)));
				return;
			}

			my @keys = sort { $a cmp $b } keys %{$list || {}};
			
			sub htmlify
			{
				my $value = shift;
				return '<i>(undef)</i>' if !defined $value;
				return HashNet::StorageEngine->printable_value($value) if $value !~ /[^[:print:]]/;
				
				my $mimetype = HashNet::StorageEngine->discover_mimetype($value);
				if($mimetype =~ /^image/)
				{
					my $base64 = encode_base64($value); 
					$base64 =~ s/\n//g;
					return "<img src='data:$mimetype;base64,$base64'>";
				}
				
				return "<i>Binary Data</i>, <b>$mimetype</b>, ".length($value)." bytes";
			}

			my $last_base = '';
			my @rows = map {
				my $value = ($list->{$_}->{data}      || '');
				my $ts    = ($list->{$_}->{timestamp} || '-');
				my $en    = ($list->{$_}->{edit_num}  || '-');
				#$value =~ s/$path/<b>$path<\/b>/;
				my @base = split /\//; pop @base; my $b=join('',@base);
				my $out = ""
				. "<tr".($b ne $last_base ? " class=divider-top":"").">"
				. "<td>". stylize_key($_, $path)     ."</td>"
				. "<td>". htmlify($value) ."</td>"
				. "<td nowrap>". date($ts) ."</td>"
				#. "<td>". $en ."</td>"
				. "</tr>";
				$last_base = $b;
				$out;
			} @keys;
			
			$path =~ s/'/&#39;/g;
			
			http_respond($res, 'text/html',
				"<html>"
				. "<head><title>Query - HashNet StorageEngine Server</title></head>"
				. "<link rel='stylesheet' type='text/css' href='/basicstyles.css' />"
				. "<body><h1><a href='/'><img src='/hashnet-logo.png' border=0 align='absmiddle'></a> Query - HashNet StorageEngine Server</h1>"
				. "<form action='/db/search'>Search: <input name=path value='$path'> <input type=submit value='Search'></form>"
				. "<h3>" . ($path eq '/' ? "All Results" : "Results for '$path'") . "</h3>"
				. "<table border=1><thead><th>Key</th><th>Value</th><th>Time</th></thead>"
				. "<tbody>"
				. join("\n", @rows)
				. "</tbody></table>"
				. "<hr/>"
				. "<p><font size=-1><i>HashNet StorageEngine, Version <b>$HashNet::StorageEngine::VERSION</b>, date <b>". `date`. "</b></i></p>"
				#. "<script>setTimeout(function(){window.location.reload()}, 1000)</script>"
				. "</body></html>"
			);
		}});
		
			
		sub stylize_url
		{
			my $u = URI->new(shift);
			return "<span class=url><span class=proto>http://</span><span class=host>".$u->host."</span>:<span class=port>".$u->port."</span><span class=path>".$u->path."</span></span>";
		}
		
		# setup a page to list peers
		#$httpd->reg_cb('/db/peers' => sub 
		$httpd->mount('/db/peers' => { handler => sub
		{
			my ($req, $res) = @_;
			
			my @peers = @{ $self->engine->peers };
			
			#my $peer_tmp = $peers[0]; 
			#logmsg "TRACE", "PeerServer: /db/peers:  $peer_tmp->{url} \t $peer_tmp->{distance_metric} <-\n";
			if(http_param($req, 'format') eq 'json')
			{
				my @list = map {
					{
						url          => $_->{url},
						name         => $_->{node_info}->{name},
						node_uuid    => $_->{node_info}->{uuid},
						host_down    => $_->{host_down} ? 1:0,
						host_up      => $_->{host_down} ? 0:1,
						latency      => $_->{distance_metric}, 
						last_tx_sent => $_->{last_tx_sent},
						last_seen    => $_->{last_seen},
					}
				} @peers;
				
				return http_respond($res, 'application/json', encode_json(\@list));
				
			}

			# Only will load changes if changed in another thread
			my @rows = map { "" 
				. "<tr>"
				. "<td><a href='$_->{url}' title='Try to visit $_->{url}'>" . ($_->{node_info}->{name} || stylize_url($_->{url})). "</a></td>"
				. "<td>".($_->host_down? "<i>Down</i>" : "<b>Up</b>")."</td>"
				. "<td>" . ($_->{distance_metric} || "") . "</td>"
				. "<td>" . ($_->{version} || '(Unknown)') . "</td>"
				. "<td>" . (defined($_->{last_tx_sent}) ? $_->{last_tx_sent} : '?') . "</td>"
				. "<td>" . ($_->{last_seen} || '?') . "</td>"
				. "</tr>"
			} @peers;
			
			my $tx = $self->engine->tx_db->length - 1;
			
			http_respond($res, 'text/html',
				"<html>"
				. "<head><title>Peers - HashNet StorageEngine Server</title></head>"
				. "<body><h1><a href='/'><img src='/hashnet-logo.png' border=0 align='absmiddle'></a> Peers - HashNet StorageEngine Server</h1>"
				. "<link rel='stylesheet' type='text/css' href='/basicstyles.css' />"
				. "<table border=1><thead><th>Peer</th><th>Status</th><th>Latency</th><th>Version</th><th>Last TX Sent</th><th>Last Seen</th></thead>"
				. "<tbody>"
				. join("\n", @rows)
				. "</tbody></table>"
				. "<hr/>"
				. "<p><font size=-1><i>HashNet StorageEngine, Version <b>$HashNet::StorageEngine::VERSION</b>, <b>$tx</b> transactions, date <b>". `date`. "</b></i></p>"
				. "<script>setTimeout(function(){window.location.reload()}, 30000) // Peers are checked every 30 seconds on the server</script>"
				. "</body></html>"
			);
		}});
		
		
		# Register our handlers - each is prefixed with '/db/'
		my %dispatch = (
			'tr_stream'=> \&resp_tr_stream,
			'tr_push'  => \&resp_tr_push,
			'tr_poll'  => \&resp_tr_poll,
			'get'      => \&resp_get,
			'put'      => \&resp_put,
			'ver'      => \&resp_ver,
			'reg_peer' => \&resp_reg_peer,
			'bin_file' => \&resp_bin_file,
			'clone_db' => \&resp_clone_db,
			# ...
		);
		
		# Register with server
		foreach my $key (keys %dispatch)
		{
			$httpd->mount('/db/'. $key => { handler => $dispatch{$key} });
		}
		
# 		if(my $pid = fork)
# 		{
# 			print "[TRACE] PeerServer: Forked $pid, returning\n";
# 			$self->{server_pid} = $pid;
# 			return $self;
# 		}

		#$self->run;
		#exit(-1); # we're in a forked copy, exit
		 
		return $self;
	}

	sub load_config
	{
		my $self = shift;
		
		if(ref($CONFIG_FILE) eq 'ARRAY')
		{
			my @files = @$CONFIG_FILE;
			my $found = 0;
			foreach my $file (@files)
			{
				if(-f $file)
				{
					#logmsg "DEBUG", "PeerServer: Using config file '$file'\n";
					$CONFIG_FILE = $file;
					$found = 1;
					last;
				}
			}

			if(!$found)
			{
				my $file = shift @$CONFIG_FILE;
				logmsg "WARN", "PeerServer: No config file found, using default location '$file'\n";
				$CONFIG_FILE = $file;
			}
		}
		else
		{
			#die Dumper $CONFIG_FILE;
		}
		
		#logmsg "DEBUG", "PeerServer: Loading config from $CONFIG_FILE\n";
		my $config = {};
		if(-f $CONFIG_FILE)
		{
			$config = YAML::Tiny::LoadFile($CONFIG_FILE);
		}
		#print Dumper $config;
		$self->{node_info} = $config->{node_info};
		$self->check_node_info();
	}

	sub save_config
	{
		my $self = shift;
		my $config =
		{
			node_info => $self->{node_info},
		};
		
		#logmsg "DEBUG", "PeerServer: Saving config to $CONFIG_FILE\n";
		YAML::Tiny::DumpFile($CONFIG_FILE, $config);

		return if ! $self->{node_info_changed_flag_file};

		# The timer loop will check for the existance of this file and push the node info into the storage engine
		open(FILE,">$self->{node_info_changed_flag_file}") || warn "Unable to write to $self->{node_info_changed_flag_file}: $!";
		print FILE "1\n";
		close(FILE);
	}
	
	sub check_node_info
	{
		my $self = shift;
		my $force = shift || 0;
		
		return if !$force && $self->{_node_info_audited};
		$self->{_node_info_audited} = 1;
		
		
		# Fields:
		# - Host Name
		# - WAN IP
		# - Geo locate
		# - LAN IPs
		# - MAC(s)?
		# - Host UUID
		# - OS Info
		
		$self->{node_info} ||= {};

		#logmsg "TRACE", "PeerServer: Auditing node_info() for name, UUID, and IP info\n";
		

		my $changed = 0;
		my $inf = $self->{node_info};
		my $set = sub
		{
			my ($k,$v) = @_;
			$inf->{$k} = $v;
			$changed = 1;
		};

		if(!$inf->{name})
		{
			my $name = `hostname`;
			$name =~ s/[\r\n]//g;
			$set->('name', $name);
		}
		
		if(!$inf->{uuid})
		{
			my $uuid = UUID::Generator::PurePerl->new->generate_v1->as_string();
			$set->('uuid', $uuid);
		}
		
		if(($inf->{port}||0) != $self->peer_port())
		{
			$set->('port', $self->peer_port());
		}
		
		{
			my $uptime = `uptime`;
			$uptime =~ s/[\r\n]//g;
			$set->('uptime', $uptime);
		}
		
		$set->('hashnet_ver', $HashNet::StorageEngine::VERSION)
			if ($inf->{hasnet_ver} || 0) != $HashNet::StorageEngine::VERSION;
		
		
		#if(!$inf->{wan_ip})
		# Check WAN IP every time in case it changes
		{
			my $external_ip;

# 			my $external_ip = `lynx -dump "http://checkip.dyndns.org"`;
# 			$external_ip =~ s/.*?([\d\.]+).*/$1/;
# 			$external_ip =~ s/(^\s+|\s+$)//g;
# 			
			#$external_ip = `wget -q -O - "http://checkip.dyndns.org"`;
			$external_ip = `wget -q -O - http://dnsinfo.net/cgi-bin/ip.cgi`;
			if($external_ip =~ m/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/) {
				$external_ip = $1;
			}

			$external_ip = '' if !$external_ip;
			
			$set->('wan_ip', $external_ip)
				if ($inf->{wan_ip}||'') ne $external_ip;
		}

		# TODO: Geolocate IP
		# If we have the geoIP db on this machine, then geo using Geo::IP,
		# otherwise, post a message and see if another peer can answer for us
		# https://www.google.com/search?sourceid=chrome&ie=UTF-8&q=perl+geo+locate+ip#hl=en&pwst=1&sa=X&ei=RP88UObrJsnJ0QHjl4DgCA&ved=0CB0QvwUoAQ&q=perl+geolocate+ip&spell=1&bav=on.2,or.r_gc.r_pw.r_qf.&fp=5b96907402d9468b&biw=1223&bih=510
		# http://www.drdobbs.com/web-development/geolocation-in-perl/184416182
		# http://search.cpan.org/~borisz/Geo-IP-1.40/lib/Geo/IP.pm
		# http://www.maxmind.com/app/geolite
		if(!defined $inf->{geo_info_auto})
		{
			$inf->{geo_info_auto} = 1;
		}
		$inf->{geo_info_auto} += 0; # force-cast to number
			
		if($inf->{geo_info_auto} &&
		   $inf->{wan_ip})
		{
			my @files = ('/var/lib/hashnet/GeoLiteCity.dat','/usr/local/share/GeoIP/GeoLiteCity.dat','/tmp/GeoLiteCity.dat');
			
			my $ip_data_file = undef;
			foreach my $file (@files)
			{
				if(-f $file)
				{
					$ip_data_file = $file;
					#logmsg "TRACE", "PeerServer: Using geolocation datafile '$file'\n";
				}
			}
			
			if(!$ip_data_file)
			{
				my $url = 'http://geolite.maxmind.com/download/geoip/database/GeoLiteCity.dat.gz';
				my $dest = '/tmp/GeoLiteCity.dat';
				logmsg "INFO", "PeerServer: Downloading geolocation datafile from $url\n";
				system("wget -q -O - $url > $dest.gz");
				logmsg "INFO", "PeerServer: 'gunzip'ing $dest.gz\n";
				system("gunzip $dest");
				$ip_data_file = $dest;
				
				if(!-f $ip_data_file)
				{
					print STDERR "[ERROR] PeerServer: Error downloading or unzipping $dest - GeoLocating will not work.\n";
				}
			}
			
			if(-f $ip_data_file)
			{
				my $gi = Geo::IP->open($ip_data_file, GEOIP_STANDARD);
				my $record = $gi->record_by_addr($inf->{wan_ip});
# 				my $geo_info = join(', ',
# 					$record->country_code,
# 					$record->country_code3,
# 					$record->country_name,
# 					$record->region,
# 					$record->region_name,
# 					$record->city,
# 					$record->postal_code,
# 					$record->latitude,
# 					$record->longitude,
# 					$record->time_zone,
# 					$record->area_code,
# 					$record->continent_code,
# 					$record->metro_code);

				eval {
					my $geo_info = join(', ',
						$record->city || '',
						$record->region || '',
						$record->country_code || '',
						$record->latitude || '',
						$record->longitude || '');

					$set->('geo_info', $geo_info)
						if ($inf->{geo_info}||'') ne $geo_info;
				};
				if($@)
				{
					logmsg "INFO", "Error updating geo_info for wan '$inf->{wan_ip}': $@";
				}
			}
		}

		{
			my $ip_list = join(', ', grep { $_ ne '127.0.0.1' } $self->my_ip_list);
			$set->('lan_ips', $ip_list)
				if !$inf->{lan_ips} ne $ip_list;
		}
		
		if(!$inf->{distro})
		{
			my $distro = `lsb_release -d`;
			$distro =~ s/^Description:\s*//g;
			$distro =~ s/[\r\n]//g;
			$distro =~ s/(^\s+|\s+$)//g;
			$set->('distro', $distro);
		}

		if(!$inf->{os_info})
		{
			my $info = `uname -a`;
			$info =~ s/[\r\n]//g;
			$info =~ s/(^\s+|\s+$)//g;
			
			$set->('os_info', $info);
		}

		$self->save_config if $changed;
		#logmsg "INFO", "PeerServer: Node info audit done.\n";
		
		undef $set;
	}
	
	my $FauxServerObject = undef;
	sub node_info
	{
		my $self = shift;
		my $force_check = shift || 0;
		
		if(!ref $self && $self->active_server)
		{
			$self = $self->active_server;
		}
		elsif(!ref $self)
		{
			# node_info() is a special-case routine -
			# it can be called from a program not running a server
			# so we can read our node info. (e.g. HashNet::StorageEngine::PeerServer->nodeInfo())
			# In such a case, create a faux object, load config,
			# return info, destroy object
			
			if(!$FauxServerObject)
			{
				#logmsg "DEBUG", "PeerServer: Creating faux object\n";
				$FauxServerObject = bless {}, $self;
				$FauxServerObject->load_config;
			}
			
			$self = $FauxServerObject;
		}
		
		$self->check_node_info($force_check);
		
		return $self->{node_info};
	}
	
	sub engine { shift->{engine} }
	
	sub httpd  { shift->{httpd}  }
	
	#sub run    { shift->httpd->run() }
	sub run    { shift->httpd->start() }

	sub in_request { shift->{in_request} }

	sub bin_file
	{
		my $self = shift;
		#$self->{bin_file} = shift if @_;
		$self->{bin_file} ||= '';
		#logmsg "DEBUG", "PeerServer: bin_file(): $self->{bin_file}\n";
		return $self->{bin_file};
	}
	
	sub tr_flag_db
	{
		my $self = shift;

		if(!$self->{tr_flag_db} ||
		  # Re-create the DBM::Deep object when we change PIDs -
		  # e.g. when someone forks a process that we are in.
		  # I learned the hard way (via multiple unexplainable errors)
		  # that DBM::Deep does NOT like existing before forks and used
		  # in child procs. (Ref: http://stackoverflow.com/questions/11368807/dbmdeep-unexplained-errors)
		  ($self->{_tr_flag_db_pid}||0) != $$)
		{
			$self->{tr_flag_db} = DBM::Deep->new($self->{tr_cache_file});
# 				file => $self->{tr_cache_file},
# 				locking   => 1, # enabled by default, just here to remind me
# 				autoflush => 1, # enabled by default, just here to remind me
# 				#type => DBM::Deep->TYPE_ARRAY
# 			);
			warn "Error opening $self->{tr_cache_file}: $@ $!" if ($@ || $!) && !$self->{tr_flag_db};
			$self->{_tr_flag_db_pid} = $$;
		}
		return $self->{tr_flag_db};
	}

	sub has_seen_tr
	{
		my $self = shift;
		my $tr = shift;
		
# 		my $tr_cache = $self->_read_tr_cache($self->{tr_cache_file}); #{}; #$self->{tr_cache} || {};
# 		#$tr_cache = lock_retrieve($self->{tr_cache_file}) if -f $self->{tr_cache_file};
# 		logmsg "DEBUG" ,"PeerServer: has_seen_tr(".$tr->uuid."): Dump of cache: ".Dumper($tr_cache);
# 		#logmsg "DEBUG" ,"PeerServer: has_seen_tr(".$tr->uuid."): Dump of cache: ".Dumper(\%{ $self->tr_flag_db });
# 		 
# 		return 1 if $tr_cache->{$tr->uuid};
		
		return 1 if $self->tr_flag_db->{$tr->uuid};
	}

# 	sub _read_tr_cache
# 	{
# 		my $self = shift;
# 		my $file = shift;
# 		if(!-f $file)
# 		{
# 			logmsg "DEBUG", "PeerServer: _read_tr_cache($file): File does not exist, returning empty hash.\n";
# 			return {};
# 		}
# 		open(FILE,"<$file") || die "Unable to read $file: $!";
# 		my %cache = map { s/[\r\n]//g; $_ => 1 } <FILE>;
# 		close(FILE);
# 		return \%cache;
# 	}
# 
# 	sub _write_tr_cache
# 	{
# 		my $self = shift;
# 		my $file = shift;
# 		my $cache = shift || {};
# 		my @keys = keys %{$cache || {}};
# 		if(!@keys)
# 		{
# 			logmsg "DEBUG", "PeerServer: _write_tr_cache(): Empty set of keys, file will be empty\n";
# 		}
# 		open(FILE,">$file") || die "Unable to write $file: $!";
# 		print FILE $_, "\n" foreach @keys;
# 		close(FILE);
# 	}
	
	sub mark_tr_seen
	{
		my $self = shift;
		my $tr = shift;
		
		#my $tr_cache = $self->_read_tr_cache($self->{tr_cache_file}); #{}; #$self->{tr_cache};
		#$tr_cache = lock_retrieve($self->{tr_cache_file}) if -f $self->{tr_cache_file};
		
		#$tr_cache->{$tr->uuid} = 1;
		#logmsg "DEBUG" ,"PeerServer: mark_tr_seen(".$tr->uuid."): Dump of cache: ".Dumper($tr_cache);
		

		#$self->_write_tr_cache($self->{tr_cache_file}, $tr_cache);
		
		$self->tr_flag_db->{$tr->uuid} = 1;

		#logmsg "DEBUG" ,"PeerServer: mark_tr_seen(".$tr->uuid."): Dump of cache: ".Dumper(\%{ $self->tr_flag_db });

	}

	sub DESTROY
	{
 		my $self = shift;
		
# 		kill 9, $self->{server_pid} if $self->{server_pid};

		if(!$self->{in_fork})
		{
			$self->kill_children();
			
# 		    $self->{timer_loop_pid})
# 		{
# 			logmsg "INFO", "PeerServer: DESTROY(): Killing timer loop $self->{timer_loop_pid}\n";
# 			kill 15, $self->{timer_loop_pid};
		}
 	}

	# Catch SIGTERM so that the DESTROY method (above) has a chance to kill the timer loop
 	$SIG{TERM} = sub
	{
		logmsg "INFO", "PeerServer: Caught SIGTERM, exiting\n";
		exit();
	};
	
# 	my %dispatch = (
# 		'tr_push'  => \&resp_tr_push,
# 		'get'      => \&resp_get,
# 		'put'      => \&resp_put,
# 		'ver'      => \&resp_ver,
# 		'reg_peer' => \&resp_reg_peer,
# 		'bin_file' => \&resp_bin_file,
# 		# ...
# 	);

# 	sub peeraddr
# 	{
# 		my $self = shift;
# 		$self->{peeraddr} = shift if @_;
# 		
# 		return $self->{peeraddr};
# 	}
	
# 	sub handle_request
# 	{
# 		my $self = shift;
# 		my $cgi  = shift;
# 		
# 		# from pms-core - havn't tried it in this context yet
# 		#my $hostinfo = gethostbyaddr($client->peeraddr);
# 		#$ENV{REMOTE_HOST} = ($hostinfo ? ( $hostinfo->name || $client->peerhost  ) : $client->peerhost);
# 	
# 		# If this isn't right, it's okay - it just means that resp_tr_push() will assume the
# 		# wrong (localhost) IP if the remote peer doesn't give a peer_url().
# 		# It's also used in resp_reg_peer() for the same thing - to guess the remote peer's peer url
# 		my $remote_sockaddr = getpeername( $self->stdio_handle );
# 		my ( $iport, $iaddr ) = $remote_sockaddr ? sockaddr_in($remote_sockaddr) : (undef,undef);
# 		my $peeraddr = $iaddr ? ( inet_ntoa($iaddr) || "127.0.0.1" ) : '127.0.0.1';
# 		$self->{peeraddr} = $peeraddr;
# 
# 		my $path = $cgi->path_info();
# 		logmsg "TRACE", "PeerServer: [", $self->peeraddr, "] $path\n";
# 		
# 		my @path_parts = split /\//, $path;
# 		shift @path_parts if !$path_parts[0];
# 		my $item = shift @path_parts;
# 		#print STDERR Dumper $item, \@path_parts;
# 		if($item ne 'db')
# 		{
# 			return reply_404($cgi, ': db');
# 		}
# 		
# 		if(!@path_parts)
# 		{
# 			return reply_404($cgi, ': Valid DB method not found');
# 		}
# 
# 		my $method = shift @path_parts;
# 		my $handler = $dispatch{$method};
# 
# 		$cgi->{path_parts} = \@path_parts;
# 		
# 		if (ref($handler) eq "CODE")
# 		{
# 			print "HTTP/1.0 200 OK\r\n";
# 			$handler->($self, $cgi);
# 
# 		}
# 		else
# 		{
# 			reply_404($cgi);
# 		}
# 	}

# 	sub reply_404
# 	{
# 		my $cgi = shift;
# 		my $info = shift;
# 		$info ||= '';
# 		print "HTTP/1.0 404 Not found\r\n";
# 		print $cgi->header,
# 		      $cgi->start_html('HashNet Not found '.$info),
# 		      $cgi->h1('HashNet Not found '.$info),
# 		      $cgi->end_html;
# 	}

=item C<resp_tr_push>

Handles transactions pushed from peers using
C<HashNet::StorageEngine::Peer:push()>.

After processing that transaction, it executes a software version check 
against all peers to ensure that this server is running the newest version 
of software available.

=cut
	sub resp_tr_push
	{
		# AnyEvent::HTTPD calls this as a callback, doesn't provide $self
		my $self = $ActivePeerServer;
		my ($req, $res) = @_;
		
		my $data = decode_json(uri_unescape(http_param($req, 'data')));
		#logmsg "TRACE", "PeerServer: resp_tr_push(): data=$data\n";
		
		my $cur_tx_id = $data->{cur_tx_id};
		my $node_uuid = $data->{node_uuid};

		my $peer = undef;
		my @peers = @{ $self->engine->peers };
		if($node_uuid)
		{
			foreach my $tmp (@peers)
			{
				if(($tmp->node_uuid||'') eq $node_uuid)
				{
					$peer = $tmp;
					last;
				}
			}
		}
		else
		{
			debug "PeerServer: resp_tr_push(): No node_uuid received in \$data, Dump of data: ".Dumper($data);
		}

		if($peer)
		{
			$peer->update_begin;
			if($peer->{host_down})
			{
				info "PeerServer: resp_tr_push(): Peer $peer->{node_info}->{name} ($peer->{url}) was down, marking up\n";
				$peer->{host_down} = 0;
			}

			if(defined $cur_tx_id)
			{
				$peer->{last_tx_recd} = $cur_tx_id;
				trace "PeerServer: resp_tr_push(): Updated cur_tx_id to $cur_tx_id\n";
			}
			else
			{
				logmsg 'WARN', "PeerServer: resp_tr_push(): No cur_tx_id received in data\n";
			}
			$peer->update_end;
		}
		else
		{
			trace "PeerServer: resp_tr_push(): No \$peer object, cannot check host_down or set last_tx_recd.\n";
			#debug "PeerServer: resp_tr_push(): No \$peer object, node_uuid: $node_uuid, Dump of engine peer list: ".Dumper(\@peers);
			
		}

		if($data->{format} eq 'bytes')
		{
			trace "PeerServer: resp_tr_push(): Received binary transaction push, thawing request content ...\n";
			#print Dumper $req->content;
			$data->{batch} = thaw($req->content);
			#trace "PeerServer: resp_tr_push(): Received binary transaction push, thawing request content ...\n";
		}
		
		my @batch = @{$data->{batch} || []};

		my @uuid_list;
		
		if(!@batch)
		{
			#logmsg "TRACE", "Peer: poll(): JSON: $json\n";
			logmsg "TRACE", "PeerServer: resp_tr_push(): Valid empty batch received, nothing done\n";
		}
		else
		{
			#logmsg "TRACE", "PeerServer: resp_tr_push(): Received \$data: ", Dumper $data;

			foreach my $hash (@batch)
			{
				my $tr = ref($hash) eq 'HashNet::StorageEngine::TransactionRecord' ? $hash : HashNet::StorageEngine::TransactionRecord->from_hash($hash);

				$self->tr_flag_db->lock_exclusive;

				# Prevent recusrive updates of this $tr
				if($self->tr_flag_db->{$tr->uuid} ||
				   $tr->has_been_here) # it checks internal {route_hist} against our uuid
				{
					$self->tr_flag_db->unlock;
					logmsg "TRACE", "PeerServer: resp_tr_push(): Already seen ", $tr->uuid, " - not processing\n";
				}
				else
				{
					$self->tr_flag_db->{$tr->uuid} = 1;
					$self->tr_flag_db->unlock;

					# If the tr is valid...
					if(defined $tr->key)
					{
						# logmsg "TRACE", "PeerServer: resp_tr_push(): ", $tr->key, " => ", (ref($tr->data) ? Dumper($tr->data) : ($tr->data || '')), ($url ? " (from $url)" :""). "\n"
						#	unless $tr->key =~ /^\/global\/nodes\//;

						# logmsg "TRACE", "PeerServer: resp_tr_push(): Received ", $tr->key, ", tr UUID $tr->{uuid}", ($url ? " (from $url)" :""). "\n".Dumper($tr);

						my $eng = $self->engine;

						# We dont use eng->put() here because it constructs a new tr
						if($tr->type eq 'TYPE_WRITE_BATCH')
						{
							$eng->_put_local_batch($tr->data);
						}
						else
						{
							$eng->_put_local($tr->key, $tr->data, $tr->timestamp, $tr->edit_num);
						}

						$eng->_push_tr($tr); #, $peer_url); # peer_url is the url of the peer to skip when using it out to peers
					}
				}

				push @uuid_list, $tr->uuid;
			}
		}
		
		http_respond($res, 'text/plain', encode_json( \@uuid_list ) ); #"Received $tr: " . $tr->key .  " => " . ($tr->data || ''));
	}

	sub resp_tr_stream
	{
		my $self = $ActivePeerServer;
		my ($req, $res) = @_;

		my $node_uuid = http_param($req, 'node_uuid') || '';

		my $peer = undef;
		my @peers = @{ $self->engine->peers };
		if($node_uuid)
		{
			foreach my $tmp (@peers)
			{
				if(($tmp->node_uuid||'') eq $node_uuid)
				{
					$peer = $tmp;
					last;
				}
			}
		}

		$peer->update_begin;
		my $host_was_down = 0;
		if($peer->{host_down})
		{
			$peer->{host_down} = 0;
			$host_was_down = 1;
		}
		$peer->update_end;
		$peer->put_peer_stats if $host_was_down;
		
		my $conn = $self->{current_conn};
		#print $conn "HTTP/1.1 200 OK\nContent-Type: text/html\r\n\r\n\r\n<h1>Hello, World!</h1>";
		my $BOUNDARY = "boundary".UUID::Generator::PurePerl->new->generate_v1->as_string();
		print $conn "HTTP/1.1 200 OK\n";
		print $conn "Content-type: multipart/x-mixed-replace; boundary=$BOUNDARY\n\n--$BOUNDARY\n";

		while($conn->connected)
		{
			$peer->load_changes();

			my ($listref, $end_tx_id) = $self->push_needed($peer, 1); # 1 = just get listref, don't call $peer->push()
			
			if(!defined $listref)
			{
				trace "PeerServer: resp_tr_stream(): Nothing to push\n";
				# Normally we wouldn't print anything to $conn, but for sake of debugging, we do anyway...
				print $conn "\nContent-Type: application/json\n\n{\"message\":\"Just debugging - listref was undef - which mean's you're up to date!\"}\n--$BOUNDARY\n";
			}
			else
			{
				trace "PeerServer: resp_tr_stream(): Pushing up to $end_tx_id\n";
				if(ref $listref eq 'HASH')
				{
					$listref = [%{$listref || {}}];
				}
				elsif(ref $listref eq 'HashNet::StorageEngine::TransactionRecord')
				{
					$listref = [$listref->to_hash];
				}

				my $data =
				{
					batch     => HashNet::StorageEngine::TransactionRecord::_clean_ref($listref),
					cur_tx_id => $end_tx_id,
					node_uuid => $self->node_info->{uuid},
				};

				my $json = encode_json($data);

				print $conn "\nContent-Type: application/json\n\n$json\n--$BOUNDARY\n";
			}

			sleep 1;
		}

		trace "PeerServer: resp_tr_stream(): Client disconnect, marking host down\n";

		$peer->update_begin;
		$peer->{host_down} = 1;
		$peer->update_end;

		$peer->put_peer_stats;
#
# 		print $conn "Content-type: text/plain\n"
# 			."\n"
# 			."After a few seconds this will go away and the logo will appear...\n"
# 			."--endofsection\n\n";
#
# 		sleep 1;
#
# 		print $conn "Content-type: text/plain\n"
# 			."\n"
# 			."New line!\n"
# 			."--endofsection\n";

#
# print $conn q{HTTP/1.1 200 OK
# Date: Sun, 23 Apr 2006 19:19:11 GMT
# Content-Type: multipart/x-mixed-replace;boundary="goofup101"
#
# --goofup101
# Content-type: text/plain
#
# <div>
# <div class='message'>You said: Knock knock</div>
# </div>
#
# --goofup101
# };
#
# sleep 1;
#
# print $conn q{
# Content-type: text/plain
#
# <div>
# <div class='message'>You said: Who's there?</div>
# </div>
#
# --goofup101--
# };

# 		print $conn "Content-Type: image/png\n"
# 			."\n";
#
# 		open(FILE,"<www/images/hashnet-logo.png");
# 		print $conn $_ while $_ = <FILE>;
# 		close(FILE);
#
# 		print $conn "\n"
# 			."--endofsection\n";

		close($conn);
		return 1;

	}

	sub push_needed
	{
		my $self = shift;
		my $peer = shift;
		my $get_listref = shift || 0;

		my $node_uuid = $peer->node_uuid;
		
		my $db = $self->engine->tx_db;
		my $cur_tx_id = $db->length() -1;

		my $last_tx_sent = $peer->last_tx_sent;
		$last_tx_sent = -1 if !defined $last_tx_sent;

		my $first_tx_needed = $last_tx_sent + 1;
		#logmsg 'TRACE', "PeerServer: push_needed(): $peer->{url}: last_tx_sent: $last_tx_sent, cur_tx_id: $cur_tx_id\n";

		if($cur_tx_id < 0)
		{
			debug "PeerServer: push_needed(): $peer->{url}: No transactions in database, not transmitting anything\n";
			return;
		}

		my $length = $cur_tx_id - $first_tx_needed + 1;
		if($length <= 0)
		{
			#debug "PeerServer: push_needed(): $peer->{url}: Peer is up to date with transactions (first_tx_needed: $first_tx_needed, current num: $cur_tx_id), nothing to send.\n";
			return;
		}

		if($length > 500)
		{
			$length = 500;
			$cur_tx_id = $first_tx_needed + $length;
			debug "PeerServer: push_needed(): $peer->{url}: Length>500, limiting to 500 transactions, setting cur_tx_id to $cur_tx_id\n";
		}

		#logmsg 'DEBUG', "PeerServer: push_needed(): $peer->{url}: +++ Peer needs transctions from $first_tx_needed to $cur_tx_id ($length tx), merging into single batch transaction ...\n";

		my $listref = $self->engine->generate_batch($first_tx_needed, $cur_tx_id, $node_uuid);

		if(!defined $listref)
		{
			# If $tr is undef, then merge_transactions found that $node_uuid has seen all the transactions from $first... to $cur...,
			# so we tell $node_uuid it's current
			debug "PeerServer: push_needed(): $peer->{url}: Peer has seen all transactions in the range requested (first_tx_needed: $first_tx_needed, current num: $cur_tx_id), nothing to send. Updating peer's last_tx_sent to $cur_tx_id\n";
			
			$peer->update_begin;
			$peer->{last_tx_sent} = $cur_tx_id;
			$peer->update_end;

			return wantarray ? (undef,-1) : undef if $get_listref;
		}
		else
		{

			#die "Created merged transaction: ".Dumper($tr);
			#logmsg 'DEBUG', "PeerServer: resp_tr_poll(): $peer->{url}: +++ Sending tr: ".Dumper($tr);

			#logmsg 'DEBUG', "PeerServer: push_needed(): $peer->{url}: +++ Peer needs transctions from $first_tx_needed to $cur_tx_id, sending $listref ...\n";
			logmsg 'DEBUG', "PeerServer: push_needed(): $peer->{url}: +++ Peer needs transctions tx $first_tx_needed - $cur_tx_id ($length tx)...\n";

			if($get_listref)
			{
				$peer->update_begin;
				$peer->{last_tx_sent} = $cur_tx_id;
				$peer->update_end;

				#logmsg 'DEBUG', "PeerServer: push_needed(): $peer->{url}: Peer successfully received all tx, updating last sent # to $cur_tx_id\n";
				logmsg 'DEBUG', "PeerServer: push_needed(): $peer->{url}: Successfully got tx out\n";

				return wantarray ? ($listref, $cur_tx_id) : $listref;
			}
			
			if($peer->push($listref, $cur_tx_id))
			{
				$peer->update_begin;
				$peer->{last_tx_sent} = $cur_tx_id;
				$peer->update_end;

				#logmsg 'DEBUG', "PeerServer: push_needed(): $peer->{url}: Peer successfully received all tx, updating last sent # to $cur_tx_id\n";
				logmsg 'DEBUG', "PeerServer: push_needed(): $peer->{url}: Peer successfully received all tx\n";
			}
			else
			{
				logmsg 'DEBUG', "PeerServer: push_needed(): $peer->{url}: Error pushing to peer, marking down\n";
				$peer->update_begin;
				$peer->{host_down} = 1;
				$peer->update_end;
			}
		}
	}
	
	sub resp_tr_poll
	{
		my $self = $ActivePeerServer;
		my ($req, $res) = @_;

		my $db = $self->engine->tx_db;
		my $cur_tx_id = $db->length() -1;

		my $node_uuid    = http_param($req, 'node_uuid') || '';
		my $last_tx_recd = http_param($req, 'last_tx');
		$last_tx_recd = -1 if !defined $last_tx_recd;
		
		my $peer = undef;
		my @peers = @{ $self->engine->peers };
		if($node_uuid)
		{
			foreach my $tmp (@peers)
			{
				if(($tmp->node_uuid||'') eq $node_uuid)
				{
					$peer = $tmp;
					last;
				}
			}
		}
		
		#my $printable_peer_id = $peer ? $peer->{node_info}->{name} : $node_uuid;
		my $printable_peer_id = $peer ? $peer->{url} : $node_uuid;

		if(http_param($req, 'get_cur_tx_id'))
		{
			debug "PeerServer: resp_tr_poll(): $printable_peer_id: Just getting cur_tx_id\n";
			return http_respond($res, 'application/octet-stream', '{"cur_tx_id":'.$cur_tx_id.'}');
		}

		my $first_tx_needed = $last_tx_recd + 1;
		logmsg 'TRACE', "PeerServer: resp_tr_poll(): $printable_peer_id: last_tx_recd: $last_tx_recd, cur_tx_id: $cur_tx_id\n";

		if($cur_tx_id < 0)
		{
			debug "PeerServer: resp_tr_poll(): $printable_peer_id: No transactions in database, not transmitting anything\n";
			return http_respond($res, 'application/octet-stream', encode_json { batch => undef, cur_tx_id => $cur_tx_id });
			return;
		}

		my $length = $cur_tx_id - $first_tx_needed + 1;
		if($length <= 0)
		{
			debug "PeerServer: resp_tr_poll(): $printable_peer_id: Peer is up to date with transactions (first_tx_needed: $first_tx_needed, current num: $cur_tx_id), nothing to send.\n";
			return http_respond($res, 'application/octet-stream', encode_json { batch => undef, cur_tx_id => $cur_tx_id });
		}

		if($length > 500)
		{
			$length = 500;
			$cur_tx_id = $first_tx_needed + $length;
			debug "PeerServer: resp_tr_poll(): $printable_peer_id: Length>500, limiting to 500 transactions, setting cur_tx_id to $cur_tx_id\n";
		}

		logmsg 'DEBUG', "PeerServer: resp_tr_poll(): $printable_peer_id: +++ Peer needs transctions from $first_tx_needed to $cur_tx_id ($length tx), merging into single batch transaction ...\n";

		#my $tr = $length == 1 ?
		#	HashNet::StorageEngine::TransactionRecord->from_hash($db->[$first_tx_needed])    :
		#	$self->engine->merge_transactions($first_tx_needed, $cur_tx_id, $node_uuid);

		# Changing from merge_transactions to generate_batch. Why?
		# - Merge transactions makes a NEW transaction out of a bunch of other transactions
		# - Generate batch - returns a list of transaction hashrefs (e.g. Transaction::to_hash)
		# Why?
		# - Merged TRs would make a NEW tr entry in the tr log on the other peer - which would cause the cur_tx_id to bump, which would
		# cause the that TR to be requested by the next peer, and so on and so forth - with no checks about the route history, etc,
		# because each time we created a new merged TR.
		# This way, we just make a batch listref of the TRs, and each is checked individually for route history and presence on this node 
		# (or the receiving node) before processing/adding to the DB 
		
		my $listref = $self->engine->generate_batch($first_tx_needed, $cur_tx_id, $node_uuid);
		
		# Do base64 encoding on any binary data for compat with JSON
		foreach my $tr_hash (@$listref)
		{
			HashNet::StorageEngine::TransactionRecord->base64_encode($tr_hash);
		}

		if($peer)
		{
			$peer->update_begin();
			$peer->{last_tx_sent} = $cur_tx_id;

			if($peer->{host_down})
			{
				logmsg 'DEBUG', "PeerServer: resp_tr_poll(): $printable_peer_id: Peer $peer->{url} was down, marking up\n";
				$peer->{host_down} = 0;
			}
			$peer->update_end();
		}


		if(!defined $listref)
		{
			# If $tr is undef, then merge_transactions found that $node_uuid has seen all the transactions from $first... to $cur...,
			# so we tell $node_uuid it's current
			debug "PeerServer: resp_tr_poll(): $printable_peer_id: Peer has seen all transactions in the range requested (first_tx_needed: $first_tx_needed, current num: $cur_tx_id), nothing to send.\n";

			return http_respond($res, 'application/octet-stream', encode_json { batch => undef, cur_tx_id => $cur_tx_id } );
		}

		#die "Created merged transaction: ".Dumper($tr);
		#logmsg 'DEBUG', "PeerServer: resp_tr_poll(): $printable_peer_id: +++ Sending tr: ".Dumper($tr);

		logmsg 'DEBUG', "PeerServer: resp_tr_poll(): $printable_peer_id: +++ Peer needs transctions from $first_tx_needed to $cur_tx_id, sending $listref ...\n";


		my $data = { batch => HashNet::StorageEngine::TransactionRecord::_clean_ref($listref), cur_tx_id => $cur_tx_id };
		#logmsg 'DEBUG', "PeerServer: resp_tr_poll(): $printable_peer_id: Sending \$data: ", Dumper $data;
		
		#logmsg "TRACE", "PeerServer: resp_get($key): $value\n";
		#print "Content-Type: text/plain\r\n\r\n", $value, "\n";
		return http_respond($res, 'application/octet-stream', encode_json $data);
	}

	sub resp_get
	{
		# AnyEvent::HTTPD calls this as a callback, doesn't provide $self
		my $self = $ActivePeerServer;
		my ($req, $res) = @_;
		
		my $key = http_param($req, 'key');# || '/'. join('/', @{$cgi->{path_parts} || []});
		if(!$key)
		{
			 # HTTP::Server::Brick will pick this up
			 die 'Error: No Key Given';
		}

		my %key_data;
		
		my $req_uuid = http_param($req, 'uuid');
		if(defined $req_uuid)
		{
			$self->tr_flag_db->lock_exclusive;

			# Prevent recusrive updates of this $tr
			if($self->tr_flag_db->{$req_uuid})
			{
				#NetMon::Util::unlock_file($self->{tr_cache_file});
				$self->tr_flag_db->unlock;
				
				logmsg "TRACE", "PeerServer: resp_get(): Already seen get() request ", $req_uuid, " - not processing\n";
				
				$res->code(204);
				return http_respond($res, 'text/plain', "Duplicate get() request");
			}
			else
			{
				# Flag it as seen - mark_tr_seen() will sync across all threads
				$self->tr_flag_db->{$req_uuid} = 1;

				#NetMon::Util::unlock_file($self->{tr_cache_file});
				$self->tr_flag_db->unlock;

				%key_data = $self->engine->get($key, $req_uuid);
			}
		}
		else
		{
			%key_data = $self->engine->get($key);
		}

		#$value ||= ''; # avoid warnings
		
		#logmsg "TRACE", "PeerServer: resp_get($key): $value\n";
		#print "Content-Type: text/plain\r\n\r\n", $value, "\n";
		#http_respond($res, 'application/octet-stream', $value);
		
		#logmsg "DEBUG", "PeerServer: resp_get(): URI: ", $req->uri, "\n";
		
		if(!(keys %key_data))
		{
			logmsg "WARN", "PeerServer: resp_get(): Key not found: $key\n";
			$res->code(404);
			return http_respond($res, 'text/plain', "Key not found: $key");
		}
		
		$res->header('X-HashNet-Timestamp'	=> $key_data{timestamp});
		$res->header('X-HashNet-Editnum'	=> $key_data{edit_num});
		http_respond($res, $key_data{mimetype},    $key_data{data});
	}
	
	sub resp_put
	{
		# TODO add some sort of authentication for putting
		
		# AnyEvent::HTTPD calls this as a callback, doesn't provide $self
		my $self = $ActivePeerServer;
		my ($req, $res) = @_;

		if(my $keys = http_param($req, 'keys'))
		{
			$self->engine->begin_batch_update();

			my @keys = split /,/, $keys;
			foreach my $key (@keys)
			{
				my $value = uri_unescape(http_param($req, $key));
				logmsg "TRACE", "PeerServer: resp_put(): [BATCH] $key => $value\n";
				$self->engine->put($key, $value);
			}

			$self->engine->end_batch_update();

			http_respond($res, 'text/plain', 'OK '. $keys);
		}
		else
		{
			my $key   = http_param($req, 'key'); # || '/'. join('/', @{$cgi->{path_parts} || []});
			my $value = http_param($req, 'data');
			$value    = http_param($req, 'value') if !defined $value;
			$value    = uri_unescape($value);
			
			logmsg "TRACE", "PeerServer: resp_put(): key: $key\n";
			
			if(!defined $value)
			{
				$value = $req->content;
				logmsg "WARN", "PeerServer: No value in URI and no content in body\n";
			}
			
			#logmsg "DEBUG", "PeerServer: resp_put(): URI: ", $req->uri, "\n";

			if(!$key)
			{
				# Should be propogated by HTTP::Server::Brick
				die "Error: No Key Given";
			}

			$self->engine->put($key, $value);

			#print "Content-Type: text/plain\r\n\r\n", $value, "\n";
			#http_respond($res, 'application/octet-stream', $value);
			http_respond($res, 'text/plain', 'OK '. $key);
		}
	}
	
	sub resp_ver
	{
		# AnyEvent::HTTPD calls this as a callback, doesn't provide $self
		my $self = $ActivePeerServer;
		my ($req, $res) = @_;
		
		#print Dumper \@_;
		logmsg "TRACE", "PeerServer: resp_ver(): Version query from ", $ENV{REMOTE_ADDR}, " on connection reference ", $self->{current_conn}, "\n";
		
# 		my $conn = $self->{current_conn};
# 		#print $conn "HTTP/1.1 200 OK\nContent-Type: text/html\r\n\r\n\r\n<h1>Hello, World!</h1>";
# # 		print $conn "HTTP/1.1 200 OK\n";
# # 		print $conn "Content-type: multipart/x-mixed-replace; boundary=endofsection\n\n";
# # 		
# # 		print $conn "Content-type: text/plain\n"
# # 			."\n"
# # 			."After a few seconds this will go away and the logo will appear...\n"
# # 			."--endofsection\n\n";
# # 			
# # 		sleep 1;
# # 		
# # 		print $conn "Content-type: text/plain\n"
# # 			."\n"
# # 			."New line!\n"
# # 			."--endofsection\n";
# 
# # 
# # print $conn q{HTTP/1.1 200 OK
# # Date: Sun, 23 Apr 2006 19:19:11 GMT
# # Content-Type: multipart/x-mixed-replace;boundary="goofup101"
# # 
# # --goofup101
# # Content-type: text/plain
# # 
# # <div>
# # <div class='message'>You said: Knock knock</div>
# # </div>
# # 
# # --goofup101
# # };
# # 
# # sleep 1;
# # 
# # print $conn q{
# # Content-type: text/plain
# # 
# # <div>
# # <div class='message'>You said: Who's there?</div>
# # </div>
# # 
# # --goofup101--
# # };
# 		
# # 		print $conn "Content-Type: image/png\n"
# # 			."\n";
# # 			
# # 		open(FILE,"<www/images/hashnet-logo.png");
# # 		print $conn $_ while $_ = <FILE>;
# # 		close(FILE);
# # 		
# # 		print $conn "\n"
# # 			."--endofsection\n";
# 
# 		close($conn);
# 		return 1;
	
		
		my $ver = $HashNet::StorageEngine::VERSION;

		my $db = $self->engine->tx_db;
		my $cur_tx_id = $db->length() -1;

		my $response = { version => $ver, ver_string => "HashNet StorageEngine Version $ver", node_info => $self->{node_info}, cur_tx_id => $cur_tx_id };
		
		my $upgrade_check = http_param($req, 'upgrade_check');
		if(defined $upgrade_check)
		{
			my $peer_url = http_param($req, 'peer_url');
			if($peer_url)
			{
				my $peer = $self->engine->peer($peer_url);
				if($peer)
				{
					$peer->{version} = $upgrade_check;
				}
			}
				
			$upgrade_check += 0;
			$ver += 0;
			
			my $has_new = $ver > $upgrade_check ? 1:0;
			my $has_bin = $self->bin_file       ? 1:0;
			
			$response->{has_new} = $has_new;
			$response->{has_bin} = $has_bin;
		}
		
		
		my $json = encode_json($response);
		
		#logmsg "TRACE", "PeerServer: resp_ver(): $ver, remote ver: $upgrade_check, peer_url: $peer_url, json:$json\n";
		
		#print "Content-Type: text/plain\r\n\r\n";
		#print $json;
		http_respond($res, 'text/plain', $json);
		
# 		logmsg "TRACE", "PeerServer: resp_ver(): $ver\n";
# 		#print "Content-Type: text/plain\r\n\r\n", ;
# 		$req->respond([ 200, 'OK', { 'Content-Type'  => 'text/plain' }, 
# 			"HashNet StorageEngine Version $ver" ]);
		
		# Just here to test restart logic
		#$self->request_restart;
	}

	sub resp_bin_file
	{
		# AnyEvent::HTTPD calls this as a callback, doesn't provide $self
		my $self = $ActivePeerServer;
		
		my ($req, $res) = @_;
		
		my $bin_file = $self->bin_file;
		if(!-f $bin_file || !open(F, "<$bin_file"))
		{
			#print "Content-Type: text/plain\r\n\r\nUnable to read bin_file or no bin_file defined\n";
			die 'Error: Cant Find Software:  Unable to read bin_file or no bin_file defined';
			return;
		}
		
# 		print "Content-Type: application/octet-stream\r\n\r\n";
# 		print $_ while $_ = <F>;
# 		close(F);

		logmsg "TRACE", "PeerServer: resp_bin_file(): Serving $bin_file to ", $ENV{REMOTE_ADDR}, "\n";

		my @buffer;
		push @buffer, $_ while $_ = <F>;
 		close(F);
		
		http_respond($res, 'application/octet-stream', join('', @buffer));
	}
	
	sub resp_clone_db
	{
		# AnyEvent::HTTPD calls this as a callback, doesn't provide $self
		my $self = $ActivePeerServer;

		my ($req, $res) = @_;

# 		my $get_tar = http_param($req, 'tar') eq '1';
# 
# 		if($get_tar)
# 		{
			my $db_root = $self->engine->db_root;
			my $cmd = 'cd '.$db_root.'; tar -zcvf $OLDPWD/db.tar.gz --exclude ".peer*.state" *; cd $OLDPWD';
			trace "PeerServer: resp_clone_db(): Running clone cmd: '$cmd'\n";
			system($cmd);
			
			my $out_file = 'db.tar.gz'; # in current directory
			
			if(!-f $out_file || !open(F, "<$out_file"))
			{
				#print "Content-Type: text/plain\r\n\r\nUnable to read bin_file or no bin_file defined\n";
				die 'Error: Cant Find '.$out_file.':  '.$out_file;
				return;
			}

	# 		print "Content-Type: application/octet-stream\r\n\r\n";
	# 		print $_ while $_ = <F>;
	# 		close(F);

			logmsg "TRACE", "PeerServer: resp_clone_db(): Serving $out_file\n";

			my @buffer;
			push @buffer, $_ while $_ = <F>;
			close(F);

			http_respond($res, 'application/octet-stream', join('', @buffer));
# 		}
# 		else
# 		{
# 			my 
# 		}
	}

	sub resp_reg_peer
	{
		# AnyEvent::HTTPD calls this as a callback, doesn't provide $self
		my $self = $ActivePeerServer;
		my ($req, $res) = @_;
		
		# Get the ip to guess the peer_url if not provided
		my $peer_ip  = $ENV{REMOTE_ADDR} || '';
		$peer_ip = (my_ip_list())[0] if !$peer_ip || $peer_ip eq '127.0.0.1';
		
		my $peer_url  = http_param($req, 'peer_url') || 'http://' . $peer_ip . ':' . $self->peer_port() . '/db' ;
		my $peer_ver  = http_param($req, 'ver')      || 0;
		my $peer_uuid = http_param($req, 'uuid')     || undef;
		
		#logmsg "DEBUG", "PeerServer: resp_reg_peer(): \$peer_url: $peer_url, given parm: ", http_param($req, 'peer_url'), "\n";
		
		my @possible = split /\|/, $peer_url;

		my $final_url = 0;
		my %seen;

		my @list_to_check = ();

		foreach my $possible_url (@possible)
		{
			#trace "PeerServer: resp_reg_peer(): \$possible_url: '$possible_url'\n";
			my $uri = URI->new($possible_url);

			if(is_this_host($possible_url))
			{
				my $tmp = $possible_url;
				$uri->host('127.0.0.1');
				$possible_url = $uri->as_string;
				trace "PeerServer: resp_reg_peer(): Changed '$tmp' => '$possible_url' because its localhost\n";
			}

			next if $seen{$possible_url};
			$seen{$possible_url} = 1;

			# We'll explicitly check localhost *last*
			next if $uri->host eq 'localhost' || $uri->host eq '127.0.0.1';

			push @list_to_check, $possible_url;

		}

		foreach my $possible_url (@list_to_check)
		{
			#my $result = $self->engine->add_peer($possible_url, undef, undef, $peer_uuid);
			my $result = $self->engine->add_peer($possible_url);

			# >0 means it's added
			# <0 means it's already in the list
			#  0 means we can't reach the host, not a good host
			if($result != 0)
			{
				# We still want to set final_url even if its already in the list
				# so that the peer knows that URL we expect them to provide
				# for tr_push requests, etc.
				$final_url = $possible_url;
				last;
			}
		}

		# check local host - but need at least 1 possible URI to figure out what port to check
		if(!$final_url && @possible)
		{
			my $local_uri = URI->new(shift @possible);
			my $port = $local_uri->port;
			my $local_url = "http://127.0.0.1:${port}/db";
			my $node_info = HashNet::StorageEngine::Peer->is_valid_peer($local_url);
			if(!$node_info)
			{
				# No server on that port, warn?
				logmsg "DEBUG", "PeerServer: resp_reg_peer(): Local URL '$local_url' not a valid peer\n";
			}
			elsif($node_info->{uuid} eq $self->node_info->{uuid})
			{
				logmsg "DEBUG", "PeerServer: resp_reg_peer(): Local URL '$local_url' same as *this server instance*, not a valid peer\n";
			}
			else
			{
				logmsg "DEBUG", "PeerServer: resp_reg_peer(): Local URL '$local_url' valid, trying to add to engine\n";
				#$final_url = $local_url;

				#my $result = $self->engine->add_peer($local_url, undef, undef, $peer_uuid);
				my $result = $self->engine->add_peer($local_url);

				# >0 means it's added
				# <0 means it's already in the list
				#  0 means we can't reach the host, not a good host
				if($result != 0)
				{
					# We still want to set final_url even if its already in the list
					# so that the peer knows that URL we expect them to provide
					# for tr_push requests, etc.
					$final_url = $local_url;
					#last;
				}

			}
		}

		logmsg "DEBUG", "PeerServer: resp_reg_peer(): Register options: $peer_url, final_url: $final_url\n";
		#print "Content-Type: text/plain\r\n\r\n", $final_url, "\n";

		#if($final_url && $peer_uuid)
		if($peer_uuid)
		{
			my $peer = undef;
			my @peers = @{ $self->engine->peers };
			foreach my $tmp (@peers)
			{
				if(($tmp->node_uuid||'') eq $peer_uuid)
				{
					$peer = $tmp;
					last;
				}
			}

			if($peer)
			{
				$peer->load_changes();
				if($peer->{host_down})
				{
					$peer->update_begin();
					logmsg 'DEBUG', "PeerServer: resp_reg_peer(): Peer $peer->{url} was down, marking up\n";
					$peer->{host_down} = 0;
					$peer->update_end();
				}
				else
				{
					logmsg 'DEBUG', "PeerServer: resp_reg_peer(): Peer $peer->{url} was marked up, nothing changed\n";
				}
			}
			else
			{
				logmsg 'DEBUG', "PeerServer: resp_reg_peer(): Cannot find peer for peer_uuid $peer_uuid\n";
			}
		}
		else
		{
			logmsg 'DEBUG', "PeerServer: resp_reg_peer(): No peer_uuid given, cannot check host_down status\n";
		}
		
# 		#logmsg 'DEBUG', "PeerServer: resp_reg_peer(): Returning final_url: $final_url\n";
		http_respond($res, 'text/plain', $final_url);

		$peer_url = $final_url; # for update checks below
		
		# This will cause recursion if called here (since the peer will call /ver again in an upgrade_software call)
# 		my $peer = $self->engine->peer($peer_url);
# 		if($peer)
# 		{
# 			$peer->update_begin();
# 			
# 			$peer->{version} = $peer_ver if $peer_ver;
# 			if($peer->host_down)
# 			{
# 				logmsg "INFO", "PeerServer: reg_resp_peer(): '$peer->{url}' was down, but now seems to be back up, adjusting state.\n";
# 				$peer->{host_down} = 0;
# 				$peer->update_distance_metric;
# 			}
# 			
# 			$peer->update_end();
# 		}

		
# 		# TODO Rewrite to NOT use AE Timer since it wont work now
# 		my $timer; $timer = AnyEvent->timer(after => 1, cb => sub
# 		{
# 			my $peer = $self->engine->peer($peer_url);
# 			if($peer)
# 			{
# 				$peer->update_begin();
# 				
# 				$peer->{version} = $peer_ver if $peer_ver;
# 				if($peer->host_down)
# 				{
# 					$peer->{host_down} = 0;
# 					$peer->update_distance_metric;
# 				}
# 				
# 				$peer->update_end();
# 				
# 				logmsg "TRACE", "PeerServer: resp_reg_peer(): Checking software against remote peer at $peer_url\n";
# 				$self->update_software($peer);
# 			}
# 			else
# 			{
# 				logmsg "TRACE", "PeerServer: resp_reg_peer(): Unable to check software against remote peer at $peer_url - couldn't find a Peer object in the engine's peer list\n";
# 			}
# 			
# 			undef $timer;
# 		});
		
		1;
	}
	
	sub searchlist_to_tree
	{
		my $res = shift || {};
		
		#print Dumper \%res;
		#exit;
		my $tree = {};
		
		# Build into a hash-of-hashes
		foreach my $key (keys %$res)
		{
			my $orig_key = $key;
			#print "key: $key, val: '$res{$key}'\n";
			$key =~ s/<[^\>]+?>//g;
			my @parts = split /\//, $key;
			my $current_ref = $tree;
			shift @parts;
			#print Dumper \@parts;
			while(my $item = shift @parts)
			{
				if(@parts)
				{
					$current_ref->{$item} ||= {};
					$current_ref = $current_ref->{$item};
				}
				else
				{
					$current_ref->{$item} = $res->{$orig_key};
				}
			}
			
			#die Dumper $tree;
		}
		
		return $tree;
		
		#die Dumper $tree->{global}->{nodes};
		#print Dumper $tree->{global}->{nodes};
		#exit;
	}
	
	sub build_nodeinfo_json
	{
		my $tree = shift;
		
		my $count = 0;
		
		my @json_list;
		
		sub normalize
		{
			my ($x,$y) = @_;
			return ($x cmp $y) < 0 ? "$x$y" : "$y$x";
		}
		
		my %links_added;
		
		my $nodes = $tree->{global}->{nodes};
		foreach my $node_uuid (keys %{$nodes || {}})
		{
			my $node = $nodes->{$node_uuid};
			my $geo  = $node->{geo_info};
			if(!$geo)
			{
				warn "No geo info for $node_uuid";
				next;
			}
			my ($lat, $lng) = $geo =~ /, (-?\d+\.\d+), (-?\d+\.\d+)/;
			
			#print STDERR "$node->{name} ($lat, $lng)\n";
			
		# 	my $node_json = {
		# 		uuid => $node_uuid,
		# 		name => $node->{name},
		# 		geo  => $geo,
		# 		lat  => $lat,
		# 		lng  => $lng,
		# 		x    => int(abs(int($lat * 100 - 4000)) * 1.2),
		# 		y    => int((abs(int($lng * 100 + 8000)) - 400) * 1.2),
		# 	};
		
			my %more_data = (
				lat  => $lat,
				lng  => $lng,
				x    => rand() * 800, #int(abs(int($lat * 100 - 4000)) * 1.2),
				y    => rand() * 400, #int((abs(int($lng * 100 + 8000)) - 400) * 1.2),
			);
			
			my $node_json = $node;
			$node_json->{$_} = $more_data{$_} foreach keys %more_data;
			
			my @links;
			my @peers = keys %{$node->{peers} || {}};
			foreach my $peer_uuid (@peers)
			{
				my $peer = $nodes->{$peer_uuid};
#				my $geo = $peer->{geo_info};
# 				if(!$geo)
# 				{
# 					warn "No geo info for peer $peer_uuid";
# 					next;
# 				}
#				my ($lat, $lng) = $geo =~ /, (-?\d+\.\d+), (-?\d+\.\d+)/;
				
				#print STDERR "\t -> $peer->{name} ($lat, $lng)\n";
				
				my $link_key = normalize($node_uuid, $peer_uuid);
				#if(!$links_added{$link_key})
				{
		# 			push @links,
		# 			{
		# # 				lat => $lat, 
		# # 				lng => $lng,
		# # 				x    => int(abs(int($lat * 100 - 4000)) * 1.2),
		# # 				y    => int((abs(int($lng * 100 + 8000)) - 400) * 1.2),
		# 				uuid => $peer_uuid,
		# 		 	};
					my $peer_info = $node->{peers}->{$peer_uuid};
					$peer_info->{uuid} = $peer_uuid;
					push @links, $peer_info;
					$links_added{$link_key} = 1;
					
					#print "$node->{name} -- $peer->{name};\n";
				}
				
				$node_json->{links} = \@links;
			}
		
			push @json_list, $node_json;
			$count ++;
		}
		
		#print STDERR Dumper \@json_list;
		return \@json_list;	
	}
};


1;
