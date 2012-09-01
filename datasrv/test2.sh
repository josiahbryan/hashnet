#!/bin/sh
perl ./dengpeersrv.pl \
	-p 8052 \
	-c /tmp/test/2/peers.cfg \
	-n /tmp/test/2/node.cfg \
	-d /tmp/test/2/db
