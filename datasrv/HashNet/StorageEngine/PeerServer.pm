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

# Override the start() method of ::Brick so we can add ForkManager
package HTTP::Server::Brick::ForkLimited;
{

use base 'HTTP::Server::Brick';
use Parallel::ForkManager;
use HTTP::Status;

# NOTE: This code is copied straight from Brick.pm - we just added the ForkManager code

=head2 start

Actually starts the server - this will loop indefinately, or until
the process recieves a C<HUP> signal in which case it will return after servicing
any current request, or waiting for the next timeout (which defaults to 5s - see L</new>).

=cut

sub start {
    my $self = shift;
    my $max_forks = shift || 25;
    
    my $pm = $self->{fork} ? Parallel::ForkManager->new($max_forks) : undef;

    my $__server_should_run = 1;

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

    while ($__server_should_run) {
        my $conn = $self->{daemon}->accept or next;

        # if we're a forking server, fork. The parent will wait for the next request.
        # TODO: limit number of children
        #next if $self->{fork} and fork;
        next if $self->{fork} and $pm->start;
        while (my $req = $conn->get_request) {

          # Provide an X-Brick-Remote-IP header
          my ($r_port, $r_iaddr) = Socket::unpack_sockaddr_in($conn->peername);
          my $ip = Socket::inet_ntoa($r_iaddr);
          $req->headers->remove_header('X-Brick-Remote-IP');
          $req->header('X-Brick-Remote-IP' => $ip) if defined $ip;

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

        HashNet::Util::Logging::losgmsg('TRACE',"[HTTP Request End]\n\n");

        $pm->finish if $self->{fork}; # TODO: I assume this exits so the next exit is unecessary ...
        # should use a guard object here to protect against early exit leaving zombies
        exit if $self->{fork};
    }

    $pm->wait_all_children if $self->{fork};

    unless ($self->{leave_sig_pipe_handler_alone}) {
        $SIG{'PIPE'} = $self->{_old_sig_pipe_handler};
    }

    1;
}

};

package HTTP::Server::Brick::PeerServerBase;
{

use base 'HTTP::Server::Brick';
use Parallel::ForkManager;
use HTTP::Status;

# NOTE: This code is copied straight from Brick.pm - we just added the ForkManager code

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
        while (my $req = $conn->get_request) {

          $peer_server->engine->refresh_peers;

          # Provide an X-Brick-Remote-IP header
          my ($r_port, $r_iaddr) = Socket::unpack_sockaddr_in($conn->peername);
          my $ip = Socket::inet_ntoa($r_iaddr);
          $req->headers->remove_header('X-Brick-Remote-IP');
          $req->header('X-Brick-Remote-IP' => $ip) if defined $ip;

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
	
	use Storable qw/lock_nstore lock_retrieve/;
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
		foreach ( qx{ brctl show } )
		{
			$interface = $1 if /^(\S+?)\s/;
			next unless defined $interface && $interface ne 'bridge'; # first line is 'bridge name ...';
			delete $ifs{$interface};
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
		
		# Lock peer and read in state if changed in another thread
		my $locker = $peer->update_begin;
		# $locker will call update_end when it goes out of scope

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

		my $other_peer_port = URI->new($url)->port;

		my $allow_localhost = $self->peer_port() != $other_peer_port ? 1:0;
		#logmsg "DEBUG", "PeerServer: self->peer_port:", $self->peer_port(),", other_peer_port:$other_peer_port, \$allow_localhost:$allow_localhost \n";

		# TODO - We use $other_peer_port here instead of $self->peer_port() BECAUSE we ASSUME that if the other peer is not using the
		# default peer port (our peer port), they are running over an SSH tunnel - and we ASSUME the SSH tunnel was set up with the same
		# port fowarded on either side. *ASSUMPTIONS*
		# TODO - Updated assumption - if *our port* is not the default port, then use OUR PORT when registering since we ASSUME we are testing on a non-normal port
		my @discovery_urls = map { 'http://'.$_.':'.($self->peer_port() != $DEFAULT_PORT ? $self->peer_port() : $other_peer_port).'/db' } grep { $allow_localhost ? 1 : $_ ne '127.0.0.1' } my_ip_list();
		
		#@discovery_urls = ($peer->{known_as}) if $peer->{known_as};
		
		my $payload = "peer_url=" . uri_escape(join('|', @discovery_urls)) . "&ver=$HashNet::StorageEngine::VERSION";
		#my $payload_encrypted = $payload; #HashNet::Cipher->cipher->encrypt($payload);
		
		# LWP::Simple
		my $final_url = $url . '?' . $payload;
		logmsg "TRACE", "PeerServer: reg_peer(): Trying to register as a peer at url: $final_url\n";
		#die "Test over";

		my $r;
		HashNet::StorageEngine::Peer::exec_timeout(10.0, sub
		{
			$r = LWP::Simple::get($final_url);
			$r ||= '';
		});
		
		if($r eq '')
		{
			logmsg "TRACE", "PeerServer: reg_peer(): No valid response when trying to register with peer at $url, marking as host_down\n";
			$peer->{host_down} = 1;
		}
		elsif(!$r)
		{
			$peer->{pull_only} = 1;
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
	
	sub request_restart
	{
		my $self = shift;
		
		# attempt restart
		logmsg "INFO", "PeerServer: request_restart(): Restarting server\n";
		
		my $peer_port = $self->peer_port();
# 		print "#######################\n";
# 		system("lsof -i :$peer_port");
# 		print "#######################\n";
# 		print "$0\n";
# 		print "#######################\n";

		# Tell the buildpacked.pl-created wrapper NOT to remove the payload directory.
		# I've seen it happen /sometimes/ when we kill the child, a race condition develops,
		# where the rm -rf in the buildpacked.pl stub is still removing the folder while the
		# new binary is decompressing the updated payload - resulting in a partial or 
		# corrupted payload and causing the new binary not to start up correctly, if at all.
		# So, we tell the stub to skip the 'rm -rf' after program exit and the new binary
		# will just overwrite the payload in place.
		$ENV{NO_CLEANUP} = 'true';
		
		foreach ( qx{ lsof -i :$peer_port | grep -P '(perl|$0)' } )
		{
			my ($pid) = (split /\s+/)[1];
			next if $pid eq 'PID' || $pid eq $$;  # first line of lsof has the header PID, etc
			
			# Grab the process description just for debugging/info purposes
			my @lines = split /\n/, `ps $pid`;
			shift @lines;
			
			if(@lines)
			{
				logmsg "INFO", "PeerServer: request_restart(): Killing child: $pid\n";
				logmsg "INFO", "            $lines[0]\n";
				
				# Actually kill the process
				kill 9, $pid;
			}
		}

		if($self->{timer_loop_pid})
		{
			logmsg "INFO", "PeerServer: request_restart(): Killing timer loop $self->{timer_loop_pid}\n";
			kill 15, $self->{timer_loop_pid};
		}
			

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

	our $CONFIG_FILE= ['/etc/dengpeersrv.cfg','/root/dengpeersrv.cfg','/opt/hashnet/datasrv/dengpeersrv.cfg'];

	sub new
	{
		my $class  = shift;
		my $engine;
		my $port = 8031;
		my $bin_file = '';
		
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
		}
		
		#my $self = $class->SUPER::new(peer_port());
		my $self = bless {}, $class;
		$ActivePeerServer = $self;

		
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
		logmsg "TRACE", "Node info changed flag file is $self->{node_info_changed_flag_file}\n";

		$self->{tr_cache_file} = $db_root . '.tr_flags';
		#$self->{tr_cache_file} = "/tmp/test".$self->peer_port.".db";
		#$self->{tr_cache_file} = $db_root."test".$self->peer_port.".db";
		#$self->tr_flag_db->put(test => time());
		logmsg "TRACE", "Using transaction flag file $self->{tr_cache_file}\n";
		#logmsg "DEBUG", "Test retrieve: ",$self->tr_flag_db->get('test'),"\n";


		$self->load_config;
		$self->save_config; # re-push into cloud

		
		# Fork off a event loop to fire off timed events
		if(my $pid = fork)
		{
			print "[TRACE] PeerServer: Forked timer loop as pid $pid\n";
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
			my $timer; $timer = AnyEvent->timer(after => 0.1, cb => sub
			{
				logmsg "INFO", "PeerServer: Registering with peers\n";
				my @peers = @{ $engine->peers };
				foreach my $peer (@peers)
				{
					# Try to register as a peer (locks state file automatically)
					$self->reg_peer($peer);
				}
				logmsg "INFO", "PeerServer: Registration complete\n";
				undef $timer;
			});
			
			my $w;
			my $timeout_sub; $timeout_sub = sub
			{
				my $db = $engine->tx_db;
				my $cur_tx_id = $db->length() || 0;

				logmsg "INFO", "PeerServer: Checking status of peers\n";
				my @peers = @{ $engine->peers };

				#@peers = (); # TODO JUST FOR DEBUGGING
				
				foreach my $peer (@peers)
				{
					#logmsg "DEBUG", "PeerServer: Peer check: $peer->{url}: Update begin ...\n";
					
					$peer->update_begin();

					#logmsg "DEBUG", "PeerServer: Peer check: $peer->{url}: Locked, checking ...\n";
					
					# Make sure the peer is online, check latency, etc
					$peer->update_distance_metric();

					#logmsg "DEBUG", "PeerServer: Peer check: $peer->{url}: Check done, unlocking\n";

					$peer->update_end();

					$peer->poll();
					
					$peer->put_peer_stats(); #$engine);
					
					logmsg "INFO", "PeerServer: Peer check: $peer->{url} \t $peer->{distance_metric} \t" # '$peer->{host_down}'\n"
						unless $peer->{host_down};
					#next;
					
					if(!$peer->host_down && !$self->is_this_peer($peer->url))
					{
# 						$peer->{last_tx_sent} = -1 if !defined $peer->{last_tx_sent};
# # 						if(!defined $peer->{last_tx_sent} || $peer->{last_tx_sent} < 0)
# # 						{
# # 							#$peer->{last_tx_sent} = $cur_tx_id;
# # 							# Start NEW peers right at the head
# # 							# TODO should we NOT do this?
# # 							# Or just DUMP a whole batch of transactions to the peer?
# # 							logmsg 'DEBUG', "PeerServer: +++ Peer '$peer->{url}' needs ALL transctions from 0 to $cur_tx_id, merging into single batch transaction ...\n";
# # 							my $tr = $self->engine->merge_transactions(0, $cur_tx_id);
# # 
# # 							#die "Created merged transaction: ".Dumper($tr);
# # 
# # 							$peer->update_begin();
# # 							{
# # 								logmsg 'DEBUG', "PeerServer: +++ Peer '$peer->{url}' needs ALL transctions from 0 to $cur_tx_id, sending merged batch as $tr->{uuid} ...\n";
# # 								#logmsg 'TRACE', "Mark2\n";
# # 								if($peer->push($tr))
# # 								{
# # 									#logmsg 'TRACE', "Mark3\n";
# # 									$peer->{last_tx_sent} = $cur_tx_id;
# # 								}
# # 								else
# # 								{
# # 									$peer->{host_down} = 1;
# # 								}
# # 							}
# # 							#logmsg 'TRACE', "Mark4\n";
# # 							$peer->update_end();
# # 							
# # 							
# # 						}
# 						
# 						my $first_tx_needed = $peer->{last_tx_sent} + 1;
# 						#logmsg 'TRACE', "PeerServer: Last tx sent: $peer->{last_tx_sent}, first_tx_needed: $first_tx_needed\n";
# 
# 						if($cur_tx_id < 0)
# 						{
# 							debug "PeerServer: No transactions in database, not transmitting anything\n";
# 							next;
# 						}
# 						
# 						# Logically, this shouldn't happen - if it does, it means the txlog was probably
# 						# deleted but the peer state was not. So, try to auto-fix the peer state.
# 						if(($peer->{last_tx_sent}||0) > $cur_tx_id)
# 						{
# 							$peer->update_begin();
# 							$peer->{last_tx_sent} = $cur_tx_id;
# 							$peer->update_end();
# 						}
# 
# 						my $length = $cur_tx_id - $first_tx_needed;
# 						if($length <= 0)
# 						{
# 							#debug "PeerServer: Peer $peer->{url} is up to date with transactions (first_tx_needed: $first_tx_needed, current num: $cur_tx_id), nothing to send.\n";
# 							next;
# 						}
# 
# 						logmsg 'DEBUG', "PeerServer: +++ Peer '$peer->{url}' needs ALL transctions from $first_tx_needed to $cur_tx_id ($length tx), merging into single batch transaction ...\n";
# 						my $tr = $length == 1 ?
# 							HashNet::StorageEngine::TransactionRecord->from_hash($db->[$first_tx_needed])    :
# 							$self->engine->merge_transactions($first_tx_needed, $cur_tx_id, $peer->node_uuid);
# 
# 						#die "Created merged transaction: ".Dumper($tr);
# 
# 						$peer->update_begin();
# 						{
# 							logmsg 'DEBUG', "PeerServer: +++ Peer '$peer->{url}' needs ALL transctions from $first_tx_needed to $cur_tx_id, sending merged batch as $tr->{uuid} ...\n";
# 							#logmsg 'TRACE', "Mark2\n";
# 							if($peer->push($tr))
# 							{
# 								#logmsg 'TRACE', "Mark3\n";
# 								$peer->{last_tx_sent} = $cur_tx_id;
# 							}
# 							else
# 							{
# 								$peer->{host_down} = 1;
# 							}
# 						}
# 						#logmsg 'TRACE', "Mark4\n";
# 						$peer->update_end();
# 						
# # 						logmsg 'DEBUG', "PeerServer: Sending $length transactions to $peer->{url} (first_tx_needed: $first_tx_needed, current num: $cur_tx_id)\n";
# # 
# # 						for my $idx ($first_tx_needed .. $cur_tx_id-1)
# # 						{
# # 							# peer->push() [below] could change this while we're in
# # 							# the for() loop, hence why we check this again
# # 							next if $peer->host_down;
# # 
# # 							my $data = $db->[$idx];
# # 							my $tr = HashNet::StorageEngine::TransactionRecord->from_hash($data);
# # 
# # 							# This should never happen ... why does it?
# # 							if(!$tr->{rel_id} || $tr->{rel_id} < 0)
# # 							{
# # 								$tr->{rel_id} = $idx;
# # 							}
# # 
# # 							#logmsg 'DEBUG', "PeerServer: Loaded tx $tr->{uuid}\n";
# # 							
# # 							#logmsg 'DEBUG', "PeerServer: Sending tx # $idx (up to $cur_tx_id) (relid ".($tr->{rel_id} || -1).")\n";
# # 							logmsg 'DEBUG', "PeerServer: Tx # $idx/$cur_tx_id: $tr->{key} \t => ", ("'$tr->{data}'"||"(undef)"), "\n";
# # 
# # 							# Just for debugging...
# # 							$tr->_dump_route_hist;
# # 
# # 							# If this TR has laready been to this node, then don't bother sending it
# # 							if($tr->has_been_here($peer->node_uuid))
# # 							{
# # 								$peer->update_begin();
# # 
# # 								# Update the tx# in the peer so our code doesn't think this peer is behind
# # 								$peer->{last_tx_sent} = $idx;
# # 								
# # 								logmsg 'DEBUG', "PeerServer: *** Peer '$peer->{url}' already seen tx # $idx/$cur_tx_id, uuid: $tr->{uuid}\n";
# # 
# # 								$peer->update_end();
# # 								next;
# # 							}
# # 
# # 							#logmsg 'TRACE', "Mark1\n";
# # 							#my $lock = $peer->update_begin();
# # 							#if($lock)
# # 							$peer->update_begin();
# # 							{
# # 								logmsg 'DEBUG', "PeerServer: +++ Peer '$peer->{url}' needs tx # $idx/$cur_tx_id, uuid: $tr->{uuid} ...\n";
# # 								#logmsg 'TRACE', "Mark2\n";
# # 								if($peer->push($tr))
# # 								{
# # 									#logmsg 'TRACE', "Mark3\n";
# # 									$peer->{last_tx_sent} = $idx; #$tr->{rel_id};
# # 								}
# # 								else
# # 								{
# # 									$peer->{host_down} = 1;
# # 								}
# # 							}
# # 							#logmsg 'TRACE', "Mark4\n";
# # 							$peer->update_end();
# # 							#logmsg 'TRACE', "Mark5\n";
# # 
# # 							#last TX_SEND if $peer->host_down;
# # 
# # 						}

						# Do the update after pushing off any pending transactions so nothing gets 'stuck' here by a failed update
						logmsg "INFO", "PeerServer: Peer check: $peer->{url} - checking software versions.\n";
						$self->update_software($peer);
						logmsg "INFO", "PeerServer: Peer check: $peer->{url} - version check done.\n";
					}
				}

				$self->engine->begin_batch_update();
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
				
					$self->engine->put("$key_path/cur_tx_id", $cur_tx_id)
						if ($self->engine->get("$key_path/cur_tx_id")||0) != ($cur_tx_id||0);
					
				}
				$self->engine->end_batch_update();

				undef $w;
				# Yes, I know AE has an 'interval' property - but it does not seem to work,
				# or at least I couldn't get it working. This does work though.
				$w = AnyEvent->timer (after => 30, cb => $timeout_sub );
				
				logmsg "INFO", "PeerServer: Peer check complete\n\n";
	
			};
			$w = AnyEvent->timer (after => 1, cb => $timeout_sub);

			logmsg "TRACE", "PeerServer: Starting timer event loop...\n";

			# Sometimes it doesnt start without calling this explicitly
			$timeout_sub->();
			
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
			info "Registering $abs_file as path '$key'\n";
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
			
			my $list = $self->engine->list($path);
			
			my $output = http_param($req, 'output') || 'html';
			if($output eq 'json')
			{
				http_respond($res, 'text/plain', encode_json(searchlist_to_tree($list)));
				return;
			}

			my @keys = sort { $a cmp $b } keys %{$list || {}};

			my $last_base = '';
			my @rows = map {
				my $value = ($list->{$_} || '');
				#$value =~ s/$path/<b>$path<\/b>/;
				my @base = split /\//; pop @base; my $b=join('',@base);
				my $out = ""
				. "<tr".($b ne $last_base ? " class=divider-top":"").">"
				. "<td>". stylize_key($_, $path)     ."</td>"
				. "<td>". $value ."</td>"
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
				. "<table border=1><thead><th>Key</th><th>Value</th></thead>"
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
			return "<span class=proto>http://</span><span class=host>".$u->host."</span>:<span class=port>".$u->port."</span><span class=path>".$u->path."</span>";
		}
		
		# setup a page to list peers
		#$httpd->reg_cb('/db/peers' => sub 
		$httpd->mount('/db/peers' => { handler => sub
		{
			my ($req, $res) = @_;
			
			my @peers = @{ $self->engine->peers };
			
			#my $peer_tmp = $peers[0]; 
			#logmsg "TRACE", "PeerServer: /db/peers:  $peer_tmp->{url} \t $peer_tmp->{distance_metric} <-\n";

			# Only will load changes if changed in another thread
			my @rows = map { "" 
				. "<tr>"
				. "<td><a href='$_->{url}' title='Try to visit $_->{url}' class=url>" . stylize_url($_->{url}). "</a></td>"
				. "<td>".($_->host_down? "<i>Down</i>" : "<b>Up</b>")."</td>"
				. "<td>" . ($_->{distance_metric} || "") . "</td>"
				. "<td>" . ($_->{version} || '(Unknown)') . "</td>"
				. "</tr>"
			} @peers;
			
			http_respond($res, 'text/html',
				"<html>"
				. "<head><title>Peers - HashNet StorageEngine Server</title></head>"
				. "<body><h1><a href='/'><img src='/hashnet-logo.png' border=0 align='absmiddle'></a> Peers - HashNet StorageEngine Server</h1>"
				. "<link rel='stylesheet' type='text/css' href='/basicstyles.css' />"
				. "<table border=1><thead><th>Peer</th><th>Status</th><th>Latency</th><th>Version</th></thead>"
				. "<tbody>"
				. join("\n", @rows)
				. "</tbody></table>"
				. "<hr/>"
				. "<p><font size=-1><i>HashNet StorageEngine, Version <b>$HashNet::StorageEngine::VERSION</b>, date <b>". `date`. "</b></i></p>"
				. "<script>setTimeout(function(){window.location.reload()}, 30000) // Peers are checked every 30 seconds on the server</script>"
				. "</body></html>"
			);
		}});
		
		
		# Register our handlers - each is prefixed with '/db/'
		my %dispatch = (
			'tr_push'  => \&resp_tr_push,
			'tr_poll'  => \&resp_tr_poll,
			'get'      => \&resp_get,
			'put'      => \&resp_put,
			'ver'      => \&resp_ver,
			'reg_peer' => \&resp_reg_peer,
			'bin_file' => \&resp_bin_file,
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
						$record->city,
						$record->region,
						$record->country_code,
						$record->latitude,
						$record->longitude);

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
 	}
	
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
		
		my $data = uri_unescape(http_param($req, 'data'));
		#logmsg "TRACE", "PeerServer: resp_tr_push(): data=$data\n";
		
		#my $tr = HashNet::StorageEngine::TransactionRecord->from_bytes($data);
		my $tr = HashNet::StorageEngine::TransactionRecord->from_json($data);
		logmsg "TRACE", "PeerServer: resp_tr_push(): Got tr ", $tr->uuid, ", has seen tr? ",($self->has_seen_tr($tr)?1:0),"\n";
		#$tr->_dump_route_hist;

		#NetMon::Util::lock_file($self->{tr_cache_file});
		$self->tr_flag_db->lock_exclusive;
		
		# Prevent recusrive updates of this $tr
		if($self->has_seen_tr($tr) || $tr->has_been_here) # it checks internal {route_hist} against our uuid
		{
			#NetMon::Util::unlock_file($self->{tr_cache_file});
			$self->tr_flag_db->unlock;
			logmsg "TRACE", "PeerServer: resp_tr_push(): Already seen ", $tr->uuid, " - not processing\n";
		}
		else
		{
			# Flag it as seen - mark_tr_seen() will sync across all threads
			#$self->mark_tr_seen($tr);
			my @merged_uuid_list = @{ $tr->{merged_uuid_list} || [ $tr->uuid ]};
			$self->tr_flag_db->{$_} = 1 foreach @merged_uuid_list;
		

			#NetMon::Util::unlock_file($self->{tr_cache_file});
			$self->tr_flag_db->unlock;
			
			# Update the route history so hosts down the line know not to send it back to us
			# UPDATE: Moved this call to _push_tr
			#$tr->update_route_history();
			
			# TODO: Send message back to peer
			
			# Get the ip to guess the peer_url if not provided
			my $peer_ip  = $req->{host} || '';
			$peer_ip = (my_ip_list())[0] if !$peer_ip || $peer_ip eq '127.0.0.1';
			
			# peer_url is used to tell _push_tr() to not send the same tr back to the peer that sent it to us
			my $peer_url = http_param($req, 'peer_url'); # || 'http://' . $peer_ip . ':' . $self->peer_port() . '/db' ;
			
			 
			# If the tr is valid...
			if(defined $tr->key)
			{
				logmsg "TRACE", "PeerServer: resp_tr_push(): ", $tr->key, " => ", (ref($tr->data) ? Dumper($tr->data) : ($tr->data || '')), ($peer_url ? " (from $peer_url)" :""). "\n"
					unless $tr->key =~ /^\/global\/nodes\//;
				
				my $eng = $self->engine;
				
				# We dont use eng->put() here because it constructs a new tr
				if($tr->type eq 'TYPE_WRITE_BATCH')
				{
					$eng->_put_local_batch($tr->data);
				}
				else
				{
					$eng->_put_local($tr->key, $tr->data);
				}
				
				$eng->_push_tr($tr, $peer_url); # peer_url is the url of the peer to skip when using it out to peers
			}

# 			# Check our version of software against all peers to make sure we have the latest version
# 			my @peers = @{ $self->engine->peers };
# 			foreach my $peer (@peers)
# 			{
# 				# Check software version against each peer
# 				$self->update_software($peer);
# 			}
		}
		
		http_respond($res, 'text/plain', $tr->uuid); #"Received $tr: " . $tr->key .  " => " . ($tr->data || ''));
	}

	sub resp_tr_poll
	{
		# AnyEvent::HTTPD calls this as a callback, doesn't provide $self
		my $self = $ActivePeerServer;
		my ($req, $res) = @_;

		my $db = $self->engine->tx_db;
		my $cur_tx_id = $db->length() || 0;

		my $node_uuid    = http_param($req, 'node_uuid') || '';
		my $last_tx_recd = http_param($req, 'last_tx') || -1;

		if(http_param($req, 'get_cur_tx_id'))
		{
			debug "PeerServer: resp_tr_poll(): $node_uuid: Just getting cur_tx_id\n";
			return http_respond($res, 'application/octet-stream', '{cur_tx_id:'.$cur_tx_id.'}');
		}

		my $first_tx_needed = $last_tx_recd + 1;
		logmsg 'TRACE', "PeerServer: resp_tr_poll(): $node_uuid: last_tx_recd: $last_tx_recd, cur_tx_id: $cur_tx_id\n";

		if($cur_tx_id < 0)
		{
			debug "PeerServer: resp_tr_poll(): $node_uuid: No transactions in database, not transmitting anything\n";
			return http_respond($res, 'application/octet-stream', '{is_current:true}');
			return;
		}

		my $length = $cur_tx_id - $first_tx_needed;
		if($length <= 0)
		{
			debug "PeerServer: resp_tr_poll(): $node_uuid: Peer is up to date with transactions (first_tx_needed: $first_tx_needed, current num: $cur_tx_id), nothing to send.\n";
			return http_respond($res, 'application/octet-stream', '{is_current:true}');
		}

		if($length > 500)
		{
			$length = 500;
			$cur_tx_id = $first_tx_needed + $length;
			debug "PeerServer: resp_tr_poll(): $node_uuid: Length>500, limiting to 500 transactions, setting cur_tx_id to $cur_tx_id\n";
		}

		logmsg 'DEBUG', "PeerServer: resp_tr_poll(): $node_uuid: +++ Peer needs transctions from $first_tx_needed to $cur_tx_id ($length tx), merging into single batch transaction ...\n";

		my $tr = $length == 1 ?
			HashNet::StorageEngine::TransactionRecord->from_hash($db->[$first_tx_needed])    :
			$self->engine->merge_transactions($first_tx_needed, $cur_tx_id, $node_uuid);

		#die "Created merged transaction: ".Dumper($tr);

		my $peer = undef;
		my @peers = @{ $self->engine->peers };
		foreach my $tmp (@peers)
		{
			if($tmp->node_uuid eq $node_uuid)
			{
				$peer = $tmp;
				last;
			}
		}
		
		if($peer)
		{
			$peer->update_begin();
			$peer->{last_tx_sent} = $cur_tx_id;

			if($peer->{host_down})
			{
				logmsg 'DEBUG', "PeerServer: resp_tr_poll(): $node_uuid: Peer $peer->{url} was down, marking up\n";
				$peer->{host_down} = 0;
			}
			$peer->update_end();
		}
			
		logmsg 'DEBUG', "PeerServer: resp_tr_poll(): $node_uuid: +++ Peer needs transctions from $first_tx_needed to $cur_tx_id, sending merged batch as $tr->{uuid} ...\n";


		#logmsg "TRACE", "PeerServer: resp_get($key): $value\n";
		#print "Content-Type: text/plain\r\n\r\n", $value, "\n";
		return http_respond($res, 'application/octet-stream', encode_json { batch => $tr->to_hash, cur_tx_id => $cur_tx_id } );
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

		my $value = undef;
		
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
			}
			else
			{
				# Flag it as seen - mark_tr_seen() will sync across all threads
				$self->tr_flag_db->{$req_uuid} = 1;

				#NetMon::Util::unlock_file($self->{tr_cache_file});
				$self->tr_flag_db->unlock;

				$value = $self->engine->get($key, $req_uuid);
			}
		}
		else
		{
			$value = $self->engine->get($key);
		}

		$value ||= ''; # avoid warnings
		
		
		logmsg "TRACE", "PeerServer: resp_get($key): $value\n";
		#print "Content-Type: text/plain\r\n\r\n", $value, "\n";
		http_respond($res, 'application/octet-stream', $value);
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
			my $key = http_param($req, 'key'); # || '/'. join('/', @{$cgi->{path_parts} || []});
			my $value = uri_unescape(http_param($req, 'data'));

			logmsg "TRACE", "PeerServer: resp_put($key): $value\n";

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
		#logmsg "TRACE", "PeerServer: resp_ver(): Version query from ", $req->{host}, "\n"; 
		
		my $ver = $HashNet::StorageEngine::VERSION;

		my $response = { version => $ver, ver_string => "HashNet StorageEngine Version $ver", node_info => $self->{node_info} };
		
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

		logmsg "TRACE", "PeerServer: resp_bin_file(): Serving $bin_file to ", $req->{host}, "\n";

		my @buffer;
		push @buffer, $_ while $_ = <F>;
 		close(F);
		
		http_respond($res, 'application/octet-stream', join('', @buffer));
	}
	
	sub resp_reg_peer
	{
		# AnyEvent::HTTPD calls this as a callback, doesn't provide $self
		my $self = $ActivePeerServer;
		my ($req, $res) = @_;
		
		# Get the ip to guess the peer_url if not provided
		my $peer_ip  = $req->{host} || '';
		$peer_ip = (my_ip_list())[0] if !$peer_ip || $peer_ip eq '127.0.0.1';
		
		my $peer_url = http_param($req, 'peer_url') || 'http://' . $peer_ip . ':' . $self->peer_port() . '/db' ;
		my $peer_ver = http_param($req, 'ver') || 0;
		
		#logmsg "DEBUG", "PeerServer: resp_reg_peer(): \$peer_url: $peer_url, given parm: ", http_param($req, 'peer_url'), "\n";
		
		if($peer_url =~ /\|/)
		{
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
					$uri->host('localhost');
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
				my $local_url = "http://localhost:${port}/db";
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
			
			http_respond($res, 'text/plain', $final_url);
			
			$peer_url = $final_url; # for update checks below
		}
		else
		{
			my $valid = $self->engine->add_peer($peer_url);
			
			# $valid:
			# >0 means it's added
			# <0 means it's already in the list
			#  0 means we can't reach the host, not a good host
			# See above on why we still give $peer_url if <0 above
				
			my $known_as = $valid != 0 ? $peer_url : 0;
			
			logmsg "TRACE", "PeerServer: resp_reg_peer(): $peer_url, valid: $valid, known_as:'$known_as'\n";
			#print "Content-Type: text/plain\r\n\r\n", ($valid!=0 ? $peer_url : 0), "\n";
			http_respond($res, 'text/plain', $known_as);
		}
		
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
				my $geo = $peer->{geo_info};
				if(!$geo)
				{
					warn "No geo info for peer $peer_uuid";
					next;
				}
				my ($lat, $lng) = $geo =~ /, (-?\d+\.\d+), (-?\d+\.\d+)/;
				
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
