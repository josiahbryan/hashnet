all: dengpeersrv.bin
dengpeersrv.bin: dengpeersrv.pl \
	HashNet/StorageEngine.pm \
	HashNet/StorageEngine/PeerServer.pm \
	HashNet/StorageEngine/Peer.pm \
	HashNet/StorageEngine/TransactionRecord.pm \
	HashNet/StorageEngine/PeerDiscovery.pm \
	HashNet/Util/Logging.pm \
	HashNet/Util/OnDestroy.pm \
	NetMon/Discovery.pm \
	www/viz.html
	perl make_dist.pl
