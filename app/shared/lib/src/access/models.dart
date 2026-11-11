import 'routing.dart';

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
    this.shareable = true,
    this.configuredSecrets = const [],
    this.assignedPorts = const [],
    this.route = const [],
    this.routePorts = const [],
    this.routeShortcuts = const [],
    this.routing = const {},
  });
  final String id;
  final String name;
  final String coreId;
  final String instanceId;
  final String protocolId;
  final int? port;
  final bool enabled;
  final Map<String, String> settings;
  final bool shareable;
  final List<String> configuredSecrets;
  final List<int> assignedPorts;
  static const localNode = 'local';
  final List<String> route;
  final List<int> routePorts;
  final List<RouteShortcut> routeShortcuts;
  final Map<String, NodeRouting> routing;
  String get ingress => route.firstOrNull ?? localNode;

  Connection copyWith({
    bool? enabled,
    List<int>? assignedPorts,
    List<int>? routePorts,
    List<RouteShortcut>? routeShortcuts,
    Map<String, NodeRouting>? routing,
  }) => Connection(
    id: id,
    name: name,
    coreId: coreId,
    instanceId: instanceId,
    protocolId: protocolId,
    port: port,
    enabled: enabled ?? this.enabled,
    settings: settings,
    shareable: shareable,
    configuredSecrets: configuredSecrets,
    assignedPorts: assignedPorts ?? this.assignedPorts,
    route: route,
    routePorts: routePorts ?? this.routePorts,
    routeShortcuts: routeShortcuts ?? this.routeShortcuts,
    routing: routing ?? this.routing,
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
    'shareable': shareable,
    'configuredSecrets': configuredSecrets,
    'assignedPorts': assignedPorts,
    if (route.isNotEmpty) 'route': route,
    if (routePorts.isNotEmpty) 'routePorts': routePorts,
    if (routeShortcuts.isNotEmpty)
      'routeShortcuts': [for (final link in routeShortcuts) link.toJson()],
    if (routing.isNotEmpty)
      'routing': {
        for (final entry in routing.entries) entry.key: entry.value.toJson(),
      },
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
    shareable: json['shareable'] as bool? ?? true,
    configuredSecrets: List<String>.from(
      json['configuredSecrets'] as List? ?? [],
    ),
    assignedPorts: List<int>.from(json['assignedPorts'] as List? ?? []),
    route: List<String>.from(json['route'] as List? ?? []),
    routePorts: List<int>.from(json['routePorts'] as List? ?? []),
    routeShortcuts: [
      for (final link in json['routeShortcuts'] as List? ?? const [])
        RouteShortcut.fromJson(Map<String, dynamic>.from(link as Map)),
    ],
    routing: {
      for (final entry in (json['routing'] as Map? ?? const {}).entries)
        entry.key as String: NodeRouting.fromJson(
          Map<String, dynamic>.from(entry.value as Map),
        ),
    },
  );
}

class RecipientDevice {
  const RecipientDevice({required this.id, required this.name});

  final String id;
  final String name;

  factory RecipientDevice.fromJson(Map<String, dynamic> json) =>
      RecipientDevice(id: json['id'] as String, name: json['name'] as String);

  Map<String, Object?> toJson() => {'id': id, 'name': name};
}

class Recipient {
  const Recipient({
    required this.id,
    required this.name,
    this.enabled = true,
    this.connectionIds = const [],
    this.connectionPorts = const {},
    this.devices = const [],
  });
  final String id;
  final String name;
  final bool enabled;
  final List<String> connectionIds;
  final Map<String, int> connectionPorts;
  final List<RecipientDevice> devices;

  Recipient copyWith({bool? enabled}) => Recipient(
    id: id,
    name: name,
    enabled: enabled ?? this.enabled,
    connectionIds: connectionIds,
    connectionPorts: connectionPorts,
    devices: devices,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'enabled': enabled,
    'connectionIds': connectionIds,
    'connectionPorts': connectionPorts,
    'devices': devices.map((device) => device.toJson()).toList(),
  };
  factory Recipient.fromJson(Map<String, dynamic> json) => Recipient(
    id: json['id'] as String,
    name: json['name'] as String,
    enabled: json['enabled'] as bool,
    connectionIds: List<String>.from(json['connectionIds'] as List),
    connectionPorts: Map<String, int>.from(
      json['connectionPorts'] as Map? ?? {},
    ),
    devices: [
      for (final device in json['devices'] as List? ?? const [])
        RecipientDevice.fromJson(Map<String, dynamic>.from(device as Map)),
    ],
  );
}

class CoreDescriptor {
  const CoreDescriptor(this.id, this.name);
  final String id;
  final String name;
}
