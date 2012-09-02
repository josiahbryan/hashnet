use common::sense;
package HashNet::Util::Logging;
{
	use Time::HiRes qw/time/;
	
	# base class of this module
	our @ISA = qw(Exporter);
	
	# Exporting by default
	our @EXPORT = qw(debug info trace error logmsg print_stack_trace called_from get_stack_trace);
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
	
	our $SHOW_FROM = 0;
	sub info  { lock_stdout; print sprintf('%.09f',time()), " [INFO]  [PID $$] \t", ($SHOW_FROM ? called_from(1). "\t ":""), join('', @_); unlock_stdout }
	sub trace { lock_stdout; print sprintf('%.09f',time()), " [TRACE] [PID $$] \t", ($SHOW_FROM ? called_from(1). "\t ":""), join('', @_); unlock_stdout }
	sub debug { lock_stdout; print sprintf('%.09f',time()), " [DEBUG] [PID $$] \t", ($SHOW_FROM ? called_from(1). "\t ":""), join('', @_); unlock_stdout }
	sub error { lock_stdout; print sprintf('%.09f',time()), " [ERROR] [PID $$] \t", ($SHOW_FROM ? called_from(1). "\t ":""), join('', @_); unlock_stdout }
	
	sub logmsg
	{
		my $level = uc(shift);
		$level eq 'INFO'  ? info(@_)  :
		$level eq 'TRACE' ? trace(@_) :
		$level eq 'DEBUG' ? debug(@_) :
		$level eq 'ERROR' ? error(@_) :
		                    debug(@_) ;
	}
	
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
};
1