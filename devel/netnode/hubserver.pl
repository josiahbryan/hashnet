#!/usr/bin/perl -w

use lib 'lib';
use HashNet::MP::MessageHub;
use HashNet::MP::AutoUpdater;

our $VERSION = 0.01;

$HashNet::Util::Logging::ANSI_ENABLED = 1 if $HashNet::Util::Logging::LEVEL;

HashNet::MP::AutoUpdater->new(app_ver => $VERSION);
HashNet::MP::MessageHub->new();