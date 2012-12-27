use common::sense;

{package HashNet::Util::ExecTimeout;

	# base class of this module
	our @ISA = qw(Exporter);

	# Exporting by default
	our @EXPORT = qw(exec_timeout);
	# Exporting on demand basis.
	our @EXPORT_OK = qw();

	use Time::HiRes qw/sleep alarm time/; # needed for exec_timeout
	sub exec_timeout($$)
	{
		my $timeout = shift;
		my $sub = shift;
		#debug "\t exec_timeout: \$timeout=$timeout, sub=$sub\n";

		my $timed_out = 0;
		local $@;
		eval
		{
			#debug "\t exec_timeout: in eval, timeout:$timeout\n";
			local $SIG{ALRM} = sub
			{
				#debug "\t exec_timeout: in SIG{ALRM}, dieing 'alarm'...\n";
				$timed_out = 1;
				die "alarm\n"
			};       # NB \n required
			my $previous_alarm = alarm $timeout;

			#debug "\t exec_timeout: alarm set, calling sub\n";
			$sub->(@_); # Pass any additional args given to exec_timout() to the $sub ref
			#debug "\t exec_timeout: sub done, clearing alarm\n";

			alarm $previous_alarm;
		};
		#debug "\t exec_timeout: outside eval, \$\@='$@', \$timed_out='$timed_out'\n";
		die if $@ && $@ ne "alarm\n";       # propagate errors

		$timed_out = $@ ? 1:0 if !$timed_out;
		#debug "\t \$timed_out flag='$timed_out'\n";
		return $timed_out;
	}
};
1;