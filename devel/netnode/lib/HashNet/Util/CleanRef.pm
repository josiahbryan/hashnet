
{package HashNet::Util::CleanRef;

	use common::sense;
	sub clean_ref
	{
		shift if $_[0] eq __PACKAGE__;
		
		my $ref = shift;
		return $ref if !ref($ref) || !$ref;
		if(ref $ref eq 'ARRAY' ||
		   ref $ref eq 'DBM::Deep::Array')
		{
			my @new_array;
			my @old_array = @$ref;
			foreach my $line (@old_array)
			{
				push @new_array, clean_ref($line);
			}
			return \@new_array;
		}
		#elsif(ref $ref eq 'HASH' ||
		#      ref $ref eq 'DBM::Deep::Hash')
		else
		{
			my %new_hash;
			my %old_hash = %$ref;
			my @keys = keys %old_hash;
			foreach my $key (keys %old_hash)
			{
				$new_hash{$key} = clean_ref($old_hash{$key});
			}
			return \%new_hash;
		}
		warn "HashNet::Util::CleanRef: clean_ref($ref): Could not clean ref type '".ref($ref)."'";
		return $ref;
	}
};
1;