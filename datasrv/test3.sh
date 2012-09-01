#!/bin/sh
perl ./dengpeersrv.pl \
	-p 8053 \
	-c /tmp/test/3/peers.cfg \
	-n /tmp/test/3/node.cfg \
	-d /tmp/test/3/db
