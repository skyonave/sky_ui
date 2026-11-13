class RouteShortcut {
  const RouteShortcut(this.from, this.to, this.port);

  final String from, to;
  final int port;

  factory RouteShortcut.fromJson(Map<String, dynamic> json) => RouteShortcut(
    json['from'] as String,
    json['to'] as String,
    json['port'] as int,
  );

  Map<String, Object> toJson() => {'from': from, 'to': to, 'port': port};
}

class RoutingRule {
  const RoutingRule(this.type, this.target, this.action);

  final String type, target, action;

  List<String> get targets => target
      .split(RegExp(r'[,\r\n]+'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();

  bool get matchesIp => type == 'cidr' || type == 'geoip';

  factory RoutingRule.fromJson(Map<String, dynamic> json) => RoutingRule(
    json['type'] as String,
    json['target'] as String,
    json['action'] as String,
  );

  Map<String, String> toJson() => {
    'type': type,
    'target': target,
    'action': action,
  };
}

class NodeRouting {
  const NodeRouting({this.fallback = next, this.rules = const []});

  static const next = 'next';
  static const direct = 'direct';
  static const block = 'block';
  static const nodePrefix = 'node:';
  static const maxRules = 32;
  static const maxTotalRules = 128;
  static const maxTargets = 8;
  static const maxTargetLength = 1024;
  static const matches = [
    'domain',
    'suffix',
    'wildcard',
    'keyword',
    'geosite',
    'cidr',
    'geoip',
    'port',
    'network',
  ];
  static const packetMatches = ['cidr', 'port', 'network'];

  static List<String> matchesFor(String coreId) =>
      coreId == 'amneziawg' ? packetMatches : matches;

  static bool allowsTargetList(String coreId, String type) =>
      coreId != 'amneziawg' && type != 'network';

  static bool supportsProxyCascade(String? coreId) =>
      const {'mihomo', 'sing-box', 'xray'}.contains(coreId);

  final String fallback;
  final List<RoutingRule> rules;

  bool get isDefault => fallback == next && rules.isEmpty;

  factory NodeRouting.fromJson(Map<String, dynamic> json) => NodeRouting(
    fallback: json['fallback'] as String,
    rules: [
      for (final rule in json['rules'] as List)
        RoutingRule.fromJson(Map<String, dynamic>.from(rule as Map)),
    ],
  );

  Map<String, Object?> toJson() => {
    'fallback': fallback,
    'rules': [for (final rule in rules) rule.toJson()],
  };
}

/// A reusable route definition. Credentials and allocated ports remain per connection.
class NamedRoute {
  const NamedRoute({
    required this.id,
    required this.name,
    required this.nodes,
    this.policies = const {},
  });
  final String id, name;
  final List<String> nodes;
  final Map<String, NodeRouting> policies;
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'nodes': nodes,
    'policies': {for (final e in policies.entries) e.key: e.value.toJson()},
  };
  factory NamedRoute.fromJson(Map<String, dynamic> json) => NamedRoute(
    id: json['id'] as String,
    name: json['name'] as String,
    nodes: List<String>.from(json['nodes'] as List),
    policies: {
      for (final e in (json['policies'] as Map? ?? {}).entries)
        e.key as String: NodeRouting.fromJson(
          Map<String, dynamic>.from(e.value as Map),
        ),
    },
  );
}
