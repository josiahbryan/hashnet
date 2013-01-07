#!/usr/bin/perl -w

use lib 'lib';
use HashNet::MP::MessageHub;

$HashNet::Util::Logging::ANSI_ENABLED = 1 if $HashNet::Util::Logging::LEVEL;

HashNet::MP::MessageHub->new();
