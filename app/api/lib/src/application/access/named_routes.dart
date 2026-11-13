import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/api_exception.dart';
import '../configuration/route_policy.dart';
import 'connection_commands.dart';
import 'records.dart';
import 'validation.dart';

/// Changes all bindings inside the caller's existing deployment transaction.
class NamedRouteCommands {
  const NamedRouteCommands(this.connections);
  final ConnectionCommands connections;

  Future<void> save(PanelData data, NamedRoute input, {String? id}) async {
    if (id != null && !data.namedRoutes.any((r) => r.id == id)) {
      throw const ApiException('not_found', status: 404);
    }
    if (id == null && data.namedRoutes.length >= 128) {
      throw const ApiException('route_limit', status: 422);
    }
    final name = validatedName(input.name);
    if (data.namedRoutes.any(
      (r) => r.id != id && r.name.toLowerCase() == name.toLowerCase(),
    )) {
      throw const ApiException('route_name_duplicate', status: 422);
    }
    final nodes = input.nodes;
    final available = {
      Connection.localNode,
      ...?connections.routes?.transport.nodes().keys,
    };
    if (nodes.isEmpty ||
        nodes.length > 8 ||
        nodes.toSet().length != nodes.length ||
        nodes.any((n) => !available.contains(n))) {
      throw const ApiException('route_invalid', status: 422);
    }
    final routeId = id ?? newId('route');
    final effective = nodes.length == 1 && nodes.single == Connection.localNode
        ? <String>[]
        : nodes;
    final validated = RoutePolicy.validate(
      Connection(
        id: '',
        name: name,
        coreId: 'mihomo',
        protocolId: 'vless',
        port: 10000,
        route: effective,
        routing: input.policies,
      ),
    );
    final value = NamedRoute(
      id: routeId,
      name: name,
      nodes: [...nodes],
      policies: validated,
    );
    data.namedRoutes.removeWhere((r) => r.id == routeId);
    data.namedRoutes.add(value);
    for (final record
        in data.connections.where((c) => c.value.routeId == routeId).toList()) {
      await connections.save(data, record.value, id: record.value.id);
    }
  }

  void remove(PanelData data, String id) {
    if (!data.namedRoutes.any((r) => r.id == id)) {
      throw const ApiException('not_found', status: 404);
    }
    if (data.connections.any((c) => c.value.routeId == id)) {
      throw const ApiException('route_in_use', status: 409);
    }
    data.namedRoutes.removeWhere((r) => r.id == id);
  }
}
