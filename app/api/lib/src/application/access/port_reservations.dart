import '../configuration/route_policy.dart';
import 'records.dart';

Set<int> localServicePorts(int apiPort, Iterable<int> controllerPorts) => {
  22,
  80,
  443,
  apiPort,
  ...controllerPorts,
};

/// A port belongs to its ingress host, including isolated recipient listeners.
Set<int> allocatedPortsOnNode(
  PanelData data,
  String node, {
  String? exceptConnection,
  bool exceptOwnGrants = false,
}) {
  final scoped = {
    for (final connection in data.connections)
      if (connection.value.ingress == node) connection.value.id,
  };
  return {
    for (final connection in data.connections)
      if (scoped.contains(connection.value.id) &&
          connection.value.id != exceptConnection &&
          connection.value.port != null)
        connection.value.port!,
    for (final grant in data.grants)
      if (scoped.contains(grant.connectionId) &&
          (!exceptOwnGrants || grant.connectionId != exceptConnection) &&
          int.tryParse(grant.credentials['port'] ?? '') != null)
        int.parse(grant.credentials['port']!),
    for (final connection in data.connections)
      for (final edge in RoutePolicy.edges(connection.value))
        if (connection.value.route[edge.to] == node &&
            int.tryParse(
                  connection.secrets['relay:port:${edge.index}'] ?? '',
                ) !=
                null)
          int.parse(connection.secrets['relay:port:${edge.index}']!),
  };
}
