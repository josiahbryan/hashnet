use common::sense;

package Storable::LockFirst;
{
	use Storable;


	sub logcroak {
	#Carp::croak(@_);
	die @_;
	}


	#
	# They might miss :flock in Fcntl
	#

	BEGIN {
		if (eval { require Fcntl; 1 } && exists $Fcntl::EXPORT_TAGS{'flock'}) {
			Fcntl->import(':flock');
		} else {
			eval q{
				sub LOCK_SH ()	{1}
				sub LOCK_EX ()	{2}
			};
		}
	}

	use Config;
	sub CAN_FLOCK; my $CAN_FLOCK; sub CAN_FLOCK {
		return $CAN_FLOCK if defined $CAN_FLOCK;
		require Config; import Config;
		return $CAN_FLOCK =
			$Config{'d_flock'} ||
			$Config{'d_fcntl_can_lock'} ||
			$Config{'d_lockf'};
	}


	# Internal store to file routine
	sub _store {
		my $xsptr = shift;
		my $self = shift;
		my ($file, $use_locking) = @_;
		logcroak "not a reference" unless ref($self);
		logcroak "wrong argument number" unless @_ == 2;	# No @foo in arglist
		local *FILE;
		if ($use_locking) {
			open(FILE, ">>$file") || logcroak "can't write into $file: $!";
			unless (&CAN_FLOCK) {
				die "Storable::lock_store: fcntl/flock emulation broken on $^O";
				return undef;
			}
			flock(FILE, LOCK_EX) ||
				logcroak "can't get exclusive lock on $file: $!";
			truncate FILE, 0;
			# Unlocking will happen when FILE is closed
		} else {
			open(FILE, ">$file") || logcroak "can't create $file: $!";
		}
		binmode FILE;				# Archaic systems...
		my $da = $@;				# Don't mess if called from exception handler
		my $ret;
		# Call C routine nstore or pstore, depending on network order
		eval { $ret = &$xsptr(*FILE, $self) };
		close(FILE) or $ret = undef;
		unlink($file) or warn "Can't unlink $file: $!\n" if $@ || !defined $ret;
		logcroak $@ if $@ =~ s/\.?\n$/,/;
		$@ = $da;
		return $ret ? $ret : undef;
	}

	#_store(\&Storable::pstore, {test=>`date`}, "storetest.dat",1);
	sub _store_lock
	{
		my $file = shift;
		open(FILE, ">>$file") || die "can't write into $file: $!";
		unless (&CAN_FLOCK) {
			die "Storable::lock_store: fcntl/flock emulation broken on $^O";
			return undef;
		}
		flock(FILE, LOCK_EX) ||
			die "can't get exclusive lock on $file: $!";
		return *FILE;
	}

	sub _store_exec
	{
		my $glob_ptr = shift;
		my $data = shift;
		my $file = shift;

		truncate $glob_ptr, 0;
		binmode $glob_ptr;			# Archaic systems...
		my $da = $@;				# Don't mess if called from exception handler
		my $ret;
		# Call C routine nstore or pstore, depending on network order
		eval { $ret = Storable::pstore($glob_ptr, $data) };
		close($glob_ptr) or $ret = undef;
		unlink($file) or warn "Can't unlink $file: $!\n" if $@ || !defined $ret;
		die  $@ if $@ =~ s/\.?\n$/,/;
		$@ = $da;
		return $ret ? $ret : undef;
	}

	sub new
	{
		my $class = shift;
		my $file = shift;
		my $data = shift || undef;
		my $self = bless
		{
			glob => _store_lock($file),
			file => $file,
			data => $data,
		}, $class;
		return $self;
	}

	sub save
	{
		my $self = shift;
		my $data = shift || $self->{data};
		_store_exec($self->{glob}, $data, $self->{file});
	}

# 	my $glob = _store_lock($file);
# 	_store_exec($glob, {test=>`date`});
};

print "Opening...\n";
my $store = Storable::LockFirst->new('storetest.dat');
print "Done.\n";
#sleep 999;
$store->save({test=>`date`});
