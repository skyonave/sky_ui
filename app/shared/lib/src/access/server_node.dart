class ServerNode {
  const ServerNode({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.publicKey,
    this.endpoint,
    this.relayAddress,
  });

  final String id;
  final String name;
  final String host;
  final int port;
  final String publicKey;
  final String? endpoint, relayAddress;

  factory ServerNode.fromJson(Map<String, dynamic> value) => ServerNode(
    id: value['id'] as String,
    name: value['name'] as String,
    host: value['host'] as String,
    port: value['port'] as int,
    publicKey: value['publicKey'] as String,
    endpoint: value['endpoint'] as String?,
    relayAddress: value['relayAddress'] as String?,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'publicKey': publicKey,
    if (endpoint != null) 'endpoint': endpoint!,
    if (relayAddress != null) 'relayAddress': relayAddress!,
  };
}

enum ServerOperation { status, start, stop, restart, logs }
