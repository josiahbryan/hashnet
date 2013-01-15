#!/usr/bin/perl -w

use strict;

use lib 'lib';
use HashNet::MP::MessageHub;
use HashNet::MP::AutoUpdater;

$HashNet::Util::Logging::ANSI_ENABLED = 1 if $HashNet::Util::Logging::LEVEL;

HashNet::MP::AutoUpdater->new(app_ver => $HashNet::MP::MessageHub::VERSION);
HashNet::MP::MessageHub->new();
