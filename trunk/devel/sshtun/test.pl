#===============================================================================
#Constants
#===============================================================================

# Useful symbols
sub LAQUO 	{ "\xAB" } 
sub RAQUO 	{ "\xBD" }
sub STAR	{ "\x60" }
sub HASH	{ "\x61" }
sub MIDDOT	{ "\x7E" } 

# Control sequences
sub CSI		{ "\x1B[" }
sub OSC		{ "\x1B]" }
sub ST		{ "\x1B\\" }

#Letters heigh and size
sub CHR_NORMAL      { "\x1B#5"}
sub CHR_WIDE_TOP    { "\x1B#3"}
sub CHR_WIDE_BOTTOM { "\x1B#4"}
sub CHR_WIDE        { "\x1B#6"}

#Screen control
sub VT100      { "\x1B[61\"p"}
sub INITGRAPHICS { "\x1B)0"}
sub LINES      { "\x1B(0"}
sub ASCII      { "\x1B(B"}
sub WRAP_ON    { "\x1B[?7h"}
sub WRAP_OFF   { "\x1B[?7l"}
sub REGION_ON  { "\x1B[?6h"}
sub REGION_OFF { "\x1B[?6l"}

#Deleting
sub DEL_TO_END     { "\x1B[0K"}
sub DEL_FROM_BEGIN { "\x1B[1K"}
sub DEL_LINE       { "\x1B[2K"}
sub DEL_TO_EOS     { "\x1B[0J"}
sub DEL_FROM_BOS   { "\x1B[1J"}
sub DEL_SCREEN     { "\x1B[2J"}
sub CLS            { "\x1B[2J"}

#Cursor control
sub CURSOR_OFF  { "\x1B[?25l" }
sub CURSOR_ON   { "\x1B[?25h" }
sub CURSOR_SAV  { "\x1B7"}
sub CURSOR_RST  { "\x1B8"}
sub REGION_UP   { "\x1BM"}
sub REGION_DOWN { "\x1BD"}
sub NEXT_LINE   { "\x1BE"}
sub HOME        { "\x1B[H"}



our %lines_xlate_pretty = 
(
	q	=> LINES . "q" . ASCII,
	x	=> LINES . "x" . ASCII,
	l	=> LINES . "l" . ASCII,
	k	=> LINES . "k" . ASCII,
	j	=> LINES . "j" . ASCII,
	m	=> LINES . "m" . ASCII,
	t	=> LINES . "t" . ASCII,
	u	=> LINES . "u" . ASCII,
	w	=> LINES . "w" . ASCII,
	v	=> LINES . "v" . ASCII,
	n	=> LINES . "n" . ASCII,
);

our %lines_xlate_text = 
(
	q	=> '-',
	x	=> '|',
	l	=> '+',
	k	=> '+',
	j	=> '+',
	m	=> '+',
	t	=> '|',
	u	=> '|',
	w	=> '-',
	v	=> '-',
	n	=> '+',
);

our %lines_xlate = %lines_xlate_pretty; #text;

#Line drawing
#sub HOR { LINES . "q" . ASCII}
#sub VER { LINES . "x" . ASCII}
#sub ULC { LINES . "l" . ASCII}
#sub URC { LINES . "k" . ASCII}
#sub LRC { LINES . "j" . ASCII}
#sub LLC { LINES . "m" . ASCII}
#sub LTE { LINES . "t" . ASCII}
#sub RTE { LINES . "u" . ASCII}
#sub TTE { LINES . "w" . ASCII}
#sub BTE { LINES . "v" . ASCII}
#sub CTE { LINES . "n" . ASCII}

sub HOR { $lines_xlate{q} }
sub VER { $lines_xlate{x} }
sub ULC { $lines_xlate{l} }
sub URC { $lines_xlate{k} }
sub LRC { $lines_xlate{j} }
sub LLC { $lines_xlate{m} }
sub LTE { $lines_xlate{t} }
sub RTE { $lines_xlate{u} }
sub TTE { $lines_xlate{w} }
sub BTE { $lines_xlate{v} }
sub CTE { $lines_xlate{n} }

#sub SHIFTDN	{ sprintf('%c',15)}

sub BELL	{ sprintf('%c',7)}
sub BEL		{ sprintf('%c',7)}

#Attributes
sub CLEAR     { "\x1B[0m"}
sub NORMAL    { "\x1B[0m"}
sub RESET     { "\x1B[0m"}
sub BOLD      { "\x1B[1m"}
sub DIM       { "\x1B[2m"}
sub UNDERLINE { "\x1B[4m"}
sub BLINK     { "\x1B[5m"}
sub REVERSE   { "\x1B[7m"}
sub INVERSE   { "\x1B[7m"}
sub HIDDEN    { "\x1B[8m"}

#Colors
sub BLACK   { "\x1B[30m"}
sub RED     { "\x1B[31m"}
sub GREEN   { "\x1B[32m"}
sub YELLOW  { "\x1B[33m"}
sub BLUE    { "\x1B[34m"}
sub MAGENTA { "\x1B[35m"}
sub CYAN    { "\x1B[36m"}
sub WHITE   { "\x1B[37m"}

sub ON_BLACK   { "\x1B[40m"}
sub ON_RED     { "\x1B[41m"}
sub ON_GREEN   { "\x1B[42m"}
sub ON_YELLOW  { "\x1B[43m"}
sub ON_BLUE    { "\x1B[44m"}
sub ON_MAGENTA { "\x1B[45m"}
sub ON_CYAN    { "\x1B[46m"}
sub ON_WHITE   { "\x1B[47m"}

my @non_vis = qw/
	ON_WHITE	WHITE
	ON_CYAN 	CYAN
	ON_MAGENTA 	MAGENTA
	ON_BLUE 	BLUE
	ON_YELLOW 	GREEN
	ON_GREEN 	RED
	ON_RED 		BLACK
	HIDDEN INVERSE REVERSE BLINK UNDERLINE DIM BOLD CLEAR BEL BELL
	HOME NEXT_LINE REGION_dOWN REGION_UP CURSOR_RST CURSOR_SAV CURSOR_ON CURSOR_OFF CLS DEL_SCREEN DEL_FROM_BOS DEL_TO_EOS DEL_LINE
	DEL_FROM_BEGIN DEL_TO_END REGION_OFF REGION_ON WRAP_OFF WRAP_ON ASCII LINES INITGRAPHICS VT100 CHR_WIDE CHR_WIDE_BOTTOM CHR_WIDE_TOP
	CHR_NORMAL ST OSC CSI/;
my @vis = qw/CTE BTE TTE RTE LTE LLC RCE URC ULC VER HOR MIDDOT HASH STAR RAQUO LAQUO/;

my @vals1;
push @vals1, eval "$_()" foreach @non_vis;
my @vals2;
push @vals2, eval "$_()" foreach @vis;
s/(\[|\(|\)|\]|\+|\.|\-)/\\$1/g foreach @vals1;
s/(\[|\(|\)|\]|\+|\.|\-)/\\$1/g foreach @vals2;
my $rx1 = '('.join('|',@vals1).')';
my $rx2 = '('.join('|',@vals2).')';

sub trim_ansi_codes
{
	my $str = shift;
	$str =~ s/\x1b\[\d{1,2}(?:;\d{1,2})?\w//g;
	$str=~s/$rx1//gi;
	#$str=~s/$rx2/./gi;
	$str =~ s/33m//g;
	$str;
}

1;
