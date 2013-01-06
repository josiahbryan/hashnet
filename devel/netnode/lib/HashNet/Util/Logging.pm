use common::sense;
package HashNet::Util::Logging;
{
	use Time::HiRes qw/time/;

	use Data::Dumper;
	use HashNet::Util::ANSIUtil;
	
	# base class of this module
	our @ISA = qw(Exporter);
	
	# Exporting by default
	our @EXPORT = qw(debug info trace error logmsg print_stack_trace called_from get_stack_trace date rpad pad ifdef ifdefined lock_file unlock_file Dumper);
	# Exporting on demand basis.
	our @EXPORT_OK = qw();
	
	my $stdout_lock = '.stdout';
	
	sub lock_stdout()
	{
		#NetMon::Util::lock_file($stdout_lock);
	}
	
	sub unlock_stdout() 
	{
		#NetMon::Util::unlock_file($stdout_lock);
	}
	
	# Hash to translate level 'strings' to integers for comparssion with $LEVEL
	my %INT_LEVELS =
	(
		ERROR	=> 1,
		WARN	=> 2, 
		INFO	=> 3,
		DEBUG	=> 4,
		TRACE	=> 5,
	);

	# Enable/disable ANSI color-coding of output
	our $ANSI_ENABLED = 0;
	
	# The level at which to limit logging output.
	# Anything greater than $LEVEL will not be output.
	our $LEVEL     = 99;
	
	# Set to true to show where
	our $SHOW_FROM = 0;
	
	# Use this to add custom prefix right before user text or called_from (if $SHOW_FROM set)
	our $CUSTOM_OUTPUT_PREFIX = '';

	# Used for changing line color by PID if $ANSI_ENABLED
	my %PidColorLut;
	my @PidColorList = (ON_RED.WHITE, ON_GREEN.BLACK, ON_YELLOW.BLACK, ON_BLUE.WHITE, ON_MAGENTA.BLACK, ON_CYAN.BLACK, ON_WHITE.BLACK,
	                    RED.ON_WHITE, GREEN.ON_BLACK, YELLOW.ON_BLACK, BLUE.ON_WHITE, MAGENTA.ON_BLACK, CYAN.ON_BLACK, WHITE.ON_BLACK);
	my $NextPidColor = 0;
	my $SharedRef;
	
	sub logmsg
	{
		my $level = uc(shift);
		
		my $int = $INT_LEVELS{$level};
		return if $int && $int > $LEVEL;
		
		my $called_from = undef;
		if($SHOW_FROM)
		{
			$called_from = called_from(1);
			$called_from = called_from(2) if $called_from =~ /Logging.pm/;
		}
		
		lock_stdout;
		if($ANSI_ENABLED)
		{
			my $color_on = $PidColorLut{$$};
			if(!$color_on)
			{
				srand(time);
				
				#$NextPidColor = rand($#PidColorList);
				$NextPidColor = $$ % $#PidColorList;
# 				if(!$SharedRef)
# 				{
# 					eval 'use HashNet::MP::SharedRef';
# 					$SharedRef = HashNet::MP::SharedRef->new(".logging.colorcounter");
# 				}
# 				
# 				$SharedRef->update_begin;
# 				
# 				$NextPidColor = $SharedRef->{next_color};
				
				$color_on = $PidColorList[$NextPidColor];
				
				$NextPidColor ++;
				$NextPidColor = 0 if $NextPidColor > $#PidColorList;

				$PidColorLut{$$} = $color_on;
				
# 				$SharedRef->{next_color} = $NextPidColor;
# 				$SharedRef->update_end;
				
				
			}
			print STDERR $color_on, sprintf('%.09f',time()), ' [', pad($level, 5, ' '), "] [PID ".rpad($$, 5, ' ')."]  $CUSTOM_OUTPUT_PREFIX", ($SHOW_FROM ? $called_from. "\t ":""), join('', @_), CLEAR;
		}
		else
		{
			print STDERR sprintf('%.09f',time()), ' [', pad($level, 5, ' '), "] [PID $$] \t$CUSTOM_OUTPUT_PREFIX", ($SHOW_FROM ? $called_from. "\t ":""), join('', @_);
		}
		unlock_stdout;
	}
	
	
	sub trace { logmsg 'TRACE', @_ }
	sub debug { logmsg 'DEBUG', @_ }
	sub info  { logmsg 'INFO',  @_ }
	sub warn  { logmsg 'WARN',  @_ }
	sub error { logmsg 'ERROR', @_ }
	
	
	sub called_from
	{
		my $offset = shift || 0;
		my ($package, $filename,$line) = caller(1+$offset);
		#my (undef,undef,$line) = caller(1);
		my (undef,undef,undef,$subroutine) = caller(2+$offset);
	
		$subroutine =~ s/.*::([^\:]+)$/$1/g;
		$filename =~ s/.*\/([^\/]+)$/$1/g;
		
		"$filename:$line / $subroutine()";
	}
	
	sub get_stack_trace
	{
		my $offset = 1+(shift||0);
		my $str = ""; #"Stack Trace (Offset: $offset):";
		for(my $x=0;$x<100;$x++)
		{
			#$tmp=(caller($x))[1];
			my ($package, $filename, $line, $subroutine, $hasargs,
				$wantarray, $evaltext, $is_require, $hints, $bitmask) = caller($x+$offset);
			(undef,undef,undef, $subroutine, $hasargs,
				$wantarray, $evaltext, $is_require, $hints, $bitmask) = caller($x+$offset+1);
			#print "$x:Base[1]='$tmp' ($package:$line:$subroutine)\n";
			
			if($filename && $filename ne '')
			{
				#print STDERR "\t$x: Called from $filename:$line".($subroutine?" in $subroutine":"")."\n";
				$str .= "\t$x: Called from $filename:$line".($subroutine?" in $subroutine":"")."\n";
			}
			else
			{
				return $str;
			}
		}
		return $str;
	}
	
	sub print_stack_trace
	{
		my $x = shift;
		my $st = get_stack_trace($x+1);
		print STDERR $st;
		return $st;
		
	}
	
	################
	# Following methods not really related to logging - just general utility methods

	sub date #{ my $d = `date`; chomp $d; $d=~s/[\r\n]//g; $d; };
	{
		if(@_ == 1) { @_ = (epoch=>shift) }
		my %args = @_;
		my $x = $args{epoch}||time;
		my $ty = ((localtime($x))[5] + 1900);
		my $tm =  (localtime($x))[4] + 1;
		my $td = ((localtime($x))[3]);
		my ($sec,$min,$hour) = localtime($x);
		my $date = "$ty-".rpad($tm).'-'.rpad($td);
		my $time = rpad($hour).':'.rpad($min).':'.rpad($sec);
		
		if(int($x) != $x)
		{
			my $fractional_part = $x - int($x);
			#my $ms = 1000 * $fractional_part;
			my $frac = sprintf('%.04f', $fractional_part);
			$time .= substr($frac,1);
		}
		
		#shift() ? $time : "$date $time";
		if($args{small})
		{
			my $a = 'a';
			if($hour>12)
			{
				$hour -= 12;
				$a = 'p';
				
				$hour = 12 if $hour == 0;
			}
			return int($tm).'/'.int($td).' '.int($hour).':'.rpad($min).$a;
		}
		else
		{
			return $args{array} || wantarray ? ($date,$time) : "$date $time";
		}
	}
	
	
	# Since learning more perl, I found I probably
	# could do '$_[0].=$_[1]x$_[2]' but I havn't gotten
	# around to changing (and testing) this code.
	sub pad
	{
		local $_ = ifdefined(shift,'');
		my $len = shift || 8;
		my $chr = shift || ' ';
		$_.=$chr while length()<$len;
		$_;
	}
	
	sub rpad
	{
		local $_ = ifdefined(shift , '');
		my $len = shift || 2;
		my $chr = shift || '0';
		$_=$chr.$_ while length()<$len;
		$_;
	}
	
	sub ifdefined { foreach(@_) { return $_ if defined } }
	sub ifdef { ifdefined(@_) }


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
1