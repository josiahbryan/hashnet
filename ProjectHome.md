# HashNet General Description #
HashNet is a program that can be distributed across multiple hosts (same site/local network or across the internet via SSH tunnels or properly-configured firewall port-forwarding) to collaboratively monitor network health, uptime, service availability, or related information.

# Why? #
HashNet originated because I have a number of different sites and servers to monitor, some with only limited availability to the rest of the internet, some with sketchy uptime, and some where it's alright to be down some of the time. Additionally, I wanted the information to be available at all locations without a single server being the point of failure for information collection, viewing, or distribution.

# Technical Overview #
Technically, HashNet consists of a single file that can be dropped onto any recent version of Linux. It  will do it's best to auto-discover the local network, detect any other computers running a HashNet instance, peer with them, and even update itself automatically. HashNet must be configured manually to peer with hosts over the internet or over SSH tunnels, or any it can't automatically discover on it's local network.

HashNet implements a distributed database with automatic recovery of any data not propagated due to a host being offline. Data is automatically propagated to all hosts (jumping from peer to peer, so that nodes which are not in a direct peering relationship will get any data inserted.)

HashNet builds on top of this database to implement distributed monitoring of the network and general information awareness. HashNet provides a HTTP interface from any of the nodes that can be used to view the status of the network.

# Status Note #
Currently this is all in active development. So far, I've got the general distributed database, peer auto-discovery, auto-update, data propagation, and single-file  installation all working.

I'm currently working on reworking the server to run as a forked server instead of my starting implementation of a non-forked server. I'm also working on getting proper recovery of any missed transactions due to being offline.

Not yet implemented is the network monitoring on top of the database - but that is still to come.