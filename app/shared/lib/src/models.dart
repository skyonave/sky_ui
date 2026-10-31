class Connection {
  const Connection({
    required this.id,
    required this.name,
    required this.coreId,
    required this.protocolId,
    required this.port,
    this.instanceId = 'primary',
    this.enabled = true,
    this.settings = const {},
  });
  final String id;
  final String name;
  final String coreId;
  final String instanceId;
  final String protocolId;
  final int? port;
  final bool enabled;
  final Map<String, String> settings;

  Connection copyWith({bool? enabled}) => Connection(
    id: id,
    name: name,
    coreId: coreId,
    instanceId: instanceId,
    protocolId: protocolId,
    port: port,
    enabled: enabled ?? this.enabled,
    settings: settings,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'coreId': coreId,
    'instanceId': instanceId,
    'protocolId': protocolId,
    'port': port,
    'enabled': enabled,
    'settings': settings,
  };
  factory Connection.fromJson(Map<String, dynamic> json) => Connection(
    id: json['id'] as String,
    name: json['name'] as String,
    coreId: json['coreId'] as String,
    instanceId: json['instanceId'] as String? ?? 'primary',
    protocolId: json['protocolId'] as String,
    port: json['port'] as int?,
    enabled: json['enabled'] as bool,
    settings: Map<String, String>.from(json['settings'] as Map),
  );
}

class Recipient {
  const Recipient({
    required this.id,
    required this.name,
    this.enabled = true,
    this.connectionIds = const [],
  });
  final String id;
  final String name;
  final bool enabled;
  final List<String> connectionIds;

  Recipient copyWith({bool? enabled}) => Recipient(
    id: id,
    name: name,
    enabled: enabled ?? this.enabled,
    connectionIds: connectionIds,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'enabled': enabled,
    'connectionIds': connectionIds,
  };
  factory Recipient.fromJson(Map<String, dynamic> json) => Recipient(
    id: json['id'] as String,
    name: json['name'] as String,
    enabled: json['enabled'] as bool,
    connectionIds: List<String>.from(json['connectionIds'] as List),
  );
}

class CoreDescriptor {
  const CoreDescriptor(this.id, this.name);
  final String id;
  final String name;
}
