{package HashNet::MP::SocketTerminator;

	use common::sense;
	
	# SocketTerminator is a common base class implementing an interface and common methods
	# for both the ServerHub and ClientHandle to work with.
	# Both the hub and client are just different ways of terminating a SocketWorker - they give
	# the worker some place to throw their messages and to get messages from the 'user' to send
	# across the socket.
	
	# Main differences between a hub and a client:
	# - Only one hub should be run per machine (unless on different ports - but then you have to specifify different data paths for the hub)
	#	- Multiple clients can run per machine (no data path needed - any storage is temporary and not required to persist between sessions.)
	# - Hubs can route messages
	#	- Clients will send messages not destinated for their uuid to the hub they are connected to
	# - Hubs can connect to other hubs directly
	#	- Clients cant connect to other clients (clients dont run a TCP/IP server or listen on a port - they just make outgoing connections)
	# - Both clients and hubs to have node_info and UUIDs
	#	- Clients have a node_info->{type} = 'client', hubs {type} says 'hub' (genuis-level code, I know...)
	# - Hubs maintain route tables of which SocketWorkers 'have' which clients (or are hubs in general) - and have multiple connections
	#	- Clients connect to just one hub (or try multiple hubs in case on eis down)
	
	
	
	
	
	
	
	
};
1;
