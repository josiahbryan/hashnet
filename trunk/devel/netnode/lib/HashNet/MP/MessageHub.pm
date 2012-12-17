{package HashNet::MP::MessageHub;
	
	use common::sense;

	use base qw/HashNet::MP::SocketTerminator/;
	
	use HashNet::MP::SocketWorker;
	use HashNet::MP::LocalDB;
	use HashNet::MP::PeerList;

	use Data::Dumper;
	
	use File::Path qw/mkpath/;

	our $DEFAULT_CONFIG_FILE = [qw#hashnet-hub.conf /etc/hashnet-hub.conf#];
	our $DEFAULT_CONFIG =
	{
		port	 => 8031,
		uuid	 => undef,
		name	 => undef,
		data_dir => '/var/lib/hashnet',
	};
	
	my $HUB_INST = undef;
	sub inst
	{
		my $class = shift;
		
		$HUB_INST = $class->new
			if !$HUB_INST;
		
		return $HUB_INST;
	}
	
	sub new
	{
		my $class = shift;
		my %opts = @_;
		
		$opts{auto_start} = 1 if !defined $opts{auto_start};
		
		my $self = bless \%opts, $class;
		
		$self->read_config();
		$self->connect_remote_hubs();
		$self->start_server() if $opts{auto_start};
	}
	
	sub read_config
	{
		my $self = shift;
		my $config = $self->{config} || $DEFAULT_CONFIG_FILE;
		if(ref $config eq 'ARRAY')
		{
			my @list = @{$config || []};
			undef $config;
			foreach my $file (@list)
			{
				if(-f $file)
				{
					$config = $file;
				}
			}
			if(!$config)
			{
				$DEFAULT_CONFIG->{name} = `hostname -s`;
				$DEFAULT_CONFIG->{name} =~ s/[\r\n]//g;
	
				$DEFAULT_CONFIG->{uuid} = `uuidgen`;
				$DEFAULT_CONFIG->{uuid} =~ s/[\r\n]//g;
				
				$DEFAULT_CONFIG->{data_dir} = $self->{data_dir} if $self->{data_dir};
				
				warn "MessageHub: read_config: Unable to find config, using default settings: ".Dumper($DEFAULT_CONFIG);
				$self->{config} = $DEFAULT_CONFIG;
				
				$self->write_default_config();
				
				$self->check_config_items();
				return;
				
			}
		}
		
		open(FILE, "<$config") || die "MessageHub: Cannot read config '$config': $!";
		
		my @config;
		push @config, $_ while $_ = <FILE>;
		close(FILE);
		
		foreach my $line (@config)
		{
			$line =~ s/[\r\n]//g;
			$line =~ s/#.*$//g;
			next if !$line;
			
			my ($key, $value) = $line =~ /^\s*(.*?):\s*(.*)$/;
			$self->{config}->{$key} = $value;
		}
		
		$self->check_config_items();
	}
	
	sub write_default_config
	{
		my $self = shift;
		my $cfg = $self->{config};
		my $file = ref $DEFAULT_CONFIG_FILE eq 'ARRAY' ? $DEFAULT_CONFIG_FILE->[0] : $DEFAULT_CONFIG_FILE;
		open(FILE, ">$file") || die "MessageHub: write_default_config: Cannot write to $file: $!";
		print FILE "$_: $cfg->{$_}\n" foreach keys %{$cfg || {}};
		close(FILE);
		warn "MessageHub: Wrote default configuration settings to $file\n";
	}
	
	sub check_config_items
	{
		my $self = shift;
		my $cfg = shift;
		
		mkpath($cfg->{data_dir}) if !-d $cfg->{data_dir};
	}
	
	sub _dbh
	{
		my $self = shift;
		my $file = $self->{config}->{data_dir} . '/hub.db';
		return HashNet::MP::LocalDB->handle($file);
	}
	
	sub connect_remote_hubs
	{
		my $self = shift;
		my $dbh = $self->_dbh;
		my $list = $dbh->{remote_hubs};
		
		if(!$list || !@{$list || []})
		{
			my $seed_hub = $self->{config}->{seed_hubs};
			if($seed_hub)
			{

				my @hubs;
				if($seed_hub =~ /,/)
				{
					@hubs = map { { 'host' => $_ }  } split /\s*,\s*/, $seed_hub;
				}
				else
				{
					@hubs = ({ host => $seed_hub });
				}

				$list =
					$dbh->{remote_hubs} = \@hubs;
			}
		}
		
		foreach my $data (@$list)
		{
			#my $sock = $self->_get_socket($data->{host});
			my $peer = HashNet::MP::PeerList->get_peer_by_host($data->{host});
			if($peer)
			{
				my $worker = $peer->open_connection($self);
			}

		}
	}
	
	sub node_info
	{
		my $self = shift;
		
		return {
			name => $self->{config}->{name},
			uuid => $self->{config}->{uuid},
			type => 'hub',
		}
	}
	
	sub start_server
	{
		my $self = shift;
		{package HashNet::MP::MessageHub::Server;
		
			use base qw(Net::Server::PreFork);
			
			sub process_request
			{
				my $self = shift;
				
				$ENV{REMOTE_ADDR} = $self->{server}->{peeraddr};
				#print STDERR "MessageHub::Server: Connect from $ENV{REMOTE_ADDR}\n";
				
				#HashNet::MP::SocketWorker->new('-', 1); # '-' = stdin/out, 1 = no fork
				
				HashNet::MP::SocketWorker->new(
					sock		=> $self->{server}->{client},
					node_info	=> $self->{node_info},
					term		=> $self->{term},
					no_fork		=> 1,
				);
				
				#print STDERR "MessageHub::Server: Disconnect from $ENV{REMOTE_ADDR}\n";
			}
		};
	
		my $obj = HashNet::MP::MessageHub::Server->new(
			port => $self->{config}->{port},
			ipv => '*'
		);
		
		$obj->{node_info} = $self->node_info,
		$obj->{term}      = $self;
		$obj->run();
	}
	
};
1;