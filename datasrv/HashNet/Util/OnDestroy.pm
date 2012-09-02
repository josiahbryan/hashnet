use common::sense;
package HashNet::Util::OnDestory;
{
	# base class of this module
	our @ISA = qw(Exporter);

	# Exporting by default
	our @EXPORT = qw(ondestroy);

	sub new { shift; ondestroy(shift) }
	
	sub ondestroy($)
	{
		my ($coderef) = @_;
		bless $coderef, __PACKAGE__;
	}
	
	sub DESTROY
	{
		shift->();
	}
}
1;
