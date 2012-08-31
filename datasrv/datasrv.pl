#!/usr/bin/perl
use strict;

=head1 Readme

Datasrv design goals:
	- Small, self-contained, data storage server
	- Path/key store, Key can be single item or a list a la log
	- Replicate to peers
		- encrypt data with key via Crypt/CBC

=head1 Planning
	- Small Self-Contained
		- To be compiled with pp
	- Path/Key Store
		- Need to make sure transactions are atomic 
		- Internal replication table to make as replicated/unreplicated
		- Consider using Data::Hive as interface (http://search.cpan.org/~rjbs/Data-Hive-1.008/lib/Data/Hive.pm)
			- Alternative is DBIx::NoSQL (http://search.cpan.org/dist/DBIx-NoSQL/lib/DBIx/NoSQL.pm)
	- Replication
		- Biggest concern
		- Needs to be 'fault tollerant'
			- Fault cases
				- All nodes could go down except self
				- Nodes loose connectivity
					- Need conflict resolution
				- One node offline
			- Therefore needs to maintain and sync a state table across nodes of other nodes
		- Node could be an external node (exposed checkin point) or internal (must checkin with an exposed node)
			- e.g. some nodes may be push-only (can push/pull data, but cannot be contacted externally)
		- Consider replicating meta data for records before replicating data itself if key over arbitrary block size (1024 or whatever)
	
	- Server
		- Consider using HTTP::Server::Simpler as the server frontend
			http://search.cpan.org/dist/HTTP-Server-Simple/lib/HTTP/Server/Simple.pm
=cut


use Crypt::Blowfish_PP;
use Crypt::CBC;
my $cipher = Crypt::CBC->new( -key    => 'hello', #`cat key`,
                              -cipher => 'Blowfish_PP'
                            );
# 
#   $ciphertext = $cipher->encrypt("This data is hush hush");
#   $plaintext  = $cipher->decrypt($ciphertext);


 #!/usr/bin/perl
{
package MyWebServer;
	
	use HTTP::Server::Simple::CGI;
	use base qw(HTTP::Server::Simple::CGI);
	
	my %dispatch = (
		'/hello' => \&resp_hello,
		'/enc'   => \&resp_enc,
		'/denc'  => \&resp_denc,
		
		# ...
	);
	
	sub handle_request {
		my $self = shift;
		my $cgi  = shift;
		
		my $path = $cgi->path_info();
		my $handler = $dispatch{$path};
		
		if (ref($handler) eq "CODE") {
			print "HTTP/1.0 200 OK\r\n";
			$handler->($cgi);
			
		} else {
			print "HTTP/1.0 404 Not found\r\n";
			print $cgi->header,
			$cgi->start_html('Not found'),
			$cgi->h1('Not found'),
			$cgi->end_html;
		}
	}
	
	sub resp_hello {
		my $cgi  = shift;   # CGI.pm object
		return if !ref $cgi;
		
		my $who = $cgi->param('name');
		
		print $cgi->header,
			$cgi->start_html("Hello"),
			$cgi->h1("Hello $who!"),
			$cgi->end_html;
	}
	
	sub resp_enc {
		my $cgi  = shift;   # CGI.pm object
		return if !ref $cgi;
		
		my $data = $cgi->param('data');
		
		print $cgi->header,
			$cgi->start_html("Encrypted"),
			$cgi->h1("Encrypted Data");
		
		my $output;
		undef $@;
		eval {
			$output = $cipher->encrypt($data);
		};
		warn "Warn: $@" if $@;
		
		
		print "<form action='/denc' method=POST>",
			"<textarea name=data rows=10 cols=40>", $output, "</textarea>",
			"<br><input type=submit value='Decrypt'></form>";
		
		print $cgi->end_html;
	}
	
	sub resp_denc {
		my $cgi  = shift;   # CGI.pm object
		return if !ref $cgi;
		
		my $data = $cgi->param('data');
		
		print $cgi->header,
			$cgi->start_html("Decrypted"),
			$cgi->h1("Decrypted Data");
		
		my $output;
		undef $@;
		eval {
			$output = $cipher->decrypt($data);
		};
		warn "Warn: $@" if $@;
		
		print "<form action='/enc' method=POST>",
			"<textarea name=data rows=10 cols=40>", $output, "</textarea>",
			"<br><input type=submit value='Encrypt'></form>";
		
		print $cgi->end_html;
	}
 
};

# my $tmp = $cipher->encrypt("test123");
# my $out = $cipher->decrypt($tmp);
# print "Out: [$out]\n";


# use DBI;
# use DB_File; # used in dbm_type option
# use MLDBM; # required for dbm_mldbm option
# 
# #  $dbh = DBI->connect('dbi:DBM:');                    # defaults to SDBM_File
# #  $dbh = DBI->connect('DBI:DBM(RaiseError=1):');      # defaults to SDBM_File
# #my $dbh = DBI->connect('dbi:DBM:dbm_type=DB_File');    # defaults to DB_File
#  #$dbh = DBI->connect('dbi:DBM:dbm_mldbm=Storable');  # MLDBM with SDBM_File
# 
#  # or
# # $dbh = DBI->connect('dbi:DBM:', undef, undef);
# my $dbh = DBI->connect('dbi:DBM:', undef, undef, {
# #     f_ext              => '.db/r',
#      f_dir              => '/path/to/dbfiles/',
# #     f_lockfile         => '.lck',
#      dbm_type           => 'DB_File',
#      dbm_mldbm          => 'FreezeThaw',
#      dbm_store_metadata => 1,
# #      dbm_berkeley_flags => {
# #          '-Cachesize' => 1000, # set a ::Hash flag
# #      },
#  });


# start the server on port 8080
#my $pid = MyWebServer->new(8080)->background();
#print "Use 'kill $pid' to stop server.\n";
print "$0: Starting server...\n";
MyWebServer->new(8199)->run();
 
