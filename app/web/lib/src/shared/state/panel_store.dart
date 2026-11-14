import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../protocols/catalog.dart';

class PanelStore {
  List<Connection> connections = [];
  List<Recipient> recipients = [];
  bool running = false;
  bool deliveryReady = false;
  Map<String, String> instanceIds = {};
  Map<String, bool> instanceReadiness = {};
  Map<String, String> routeNodes = {};
  Map<String, String> routeAddresses = {};
  Map<String, String> remoteInstanceStates = {};
  List<NamedRoute> routes = [];
  String serverName = 'Sky UI';
  String address = '';
  Map<String, List<ProtocolDefinition>> protocols = {};
  void apply(PanelSnapshot snapshot) {
    connections = snapshot.connections;
    recipients = snapshot.recipients;
    serverName = snapshot.serverName;
    address = snapshot.address;
    deliveryReady = snapshot.deliveryReady;
    protocols = snapshot.protocols;
    instanceIds = snapshot.instanceIds;
    instanceReadiness = snapshot.instanceReadiness;
    routeNodes = snapshot.routeNodes;
    routeAddresses = snapshot.routeAddresses;
    remoteInstanceStates = snapshot.remoteInstanceStates;
    routes = snapshot.routes;
  }

  String addressForNode(String node) =>
      node == Connection.localNode ? address : routeAddresses[node] ?? '';

  String endpointForNode(String node, int? port) {
    final host = addressForNode(node);
    if (host.isEmpty || port == null) return host;
    final formatted = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    return '$formatted:$port';
  }

  String connectionEndpoint(Connection connection) => endpointForNode(
    connection.ingress,
    connection.assignedPorts.firstOrNull ?? connection.port,
  );

  String remoteState(Connection c) {
    for (var i = 0; i < c.route.length; i++) {
      final node = c.route[i];
      if (node == Connection.localNode) continue;
      final core = i == 0 ? c.coreId : 'mihomo';
      final state = remoteInstanceStates['$node/$core'] ?? 'unknown';
      if (state != 'ready') return state;
    }
    return 'ready';
  }

  bool ready(Connection c) {
    if (!deliveryReady || remoteState(c) != 'ready') return false;
    if (c.ingress == Connection.localNode &&
        !(instanceReadiness[c.instanceId] ?? deliveryReady))
      return false;
    if (c.route.skip(1).contains(Connection.localNode) &&
        instanceReadiness[instanceIds['mihomo'] ?? 'primary'] != true)
      return false;
    return true;
  }

  bool supports(String? core, String? protocol) =>
      protocols[core]?.any((p) => p.id == protocol && p.available) ?? false;
  ProtocolDefinition definition(String core, String id) =>
      protocols[core]?.where((p) => p.id == id).firstOrNull ??
      protocolsForCore(core).firstWhere((p) => p.id == id);
  ProtocolDefinition protocol(String id) =>
      protocols.values.expand((v) => v).where((p) => p.id == id).firstOrNull ??
      protocolCatalog.firstWhere((p) => p.id == id);
  int get activeConnections => deliveryReady
      ? connections
            .where(
              (c) =>
                  c.enabled &&
                  ready(c) &&
                  (!c.shareable || recipientsFor(c.id).isNotEmpty),
            )
            .length
      : 0;
  int get activeRecipients => deliveryReady
      ? recipients
            .where(
              (u) =>
                  u.enabled &&
                  u.connectionIds.any(
                    (id) => connections.any(
                      (c) => c.id == id && c.enabled && ready(c),
                    ),
                  ),
            )
            .length
      : 0;
  List<Recipient> recipientsFor(String id) => recipients
      .where((u) => u.enabled && u.connectionIds.contains(id))
      .toList();
}
