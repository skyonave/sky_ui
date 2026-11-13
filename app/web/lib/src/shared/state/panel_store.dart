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
    routes = snapshot.routes;
  }

  bool ready(Connection c) => c.ingress != Connection.localNode
      ? deliveryReady
      : instanceReadiness[c.instanceId] ?? deliveryReady;

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
