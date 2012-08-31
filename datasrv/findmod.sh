perl -le "require 'AnyEvent/constants.pl'; \$mname=\"${1}.pm\";\$mname=~s#::#/#g;print \"$1 INSTALLED AT \$INC{\$mname}\";" 2>/dev/null || echo "${1} NOT INSTALLED"
