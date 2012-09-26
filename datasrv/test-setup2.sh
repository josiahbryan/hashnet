#!/bin/bash

# Alt test layout:
#  3---1---2
#  |
#  4

echo Erasing test data and re-creating test parameters...
for i in `seq 1 4`; do(rm -rf /tmp/test/$i; mkdir -p /tmp/test/$i);done;

# Setup test1
echo http://localhost:8052/db >  /tmp/test/1/peers.cfg
echo http://localhost:8053/db >> /tmp/test/1/peers.cfg

# Setup test2
echo http://localhost:8051/db >  /tmp/test/2/peers.cfg
#echo http://localhost:8051/db >> /tmp/test/2/peers.cfg

# Setup test3
echo http://localhost:8051/db >  /tmp/test/3/peers.cfg
echo http://localhost:8054/db >> /tmp/test/3/peers.cfg

# Setup test4
echo http://localhost:8053/db >  /tmp/test/4/peers.cfg
#echo http://localhost:8052/db >> /tmp/test/4/peers.cfg

