#!/bin/sh
#perl ./dengpeersrv.pl \
#./dengpeersrv.bin \
perl ./dengpeersrv.pl \
	-p 8051 \
	-c /tmp/test/1/peers.cfg \
	-n /tmp/test/1/node.cfg \
	-d /tmp/test/1/db
