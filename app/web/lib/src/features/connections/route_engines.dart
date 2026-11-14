import 'package:sky_ui_shared/sky_ui_shared.dart';

/// Engine discovery belongs to the ingress host; relay hops do not imply a
/// matching local installation of the ingress engine.
class ConnectionRouteEngines {
  ConnectionRouteEngines({required this.localInstalled});

  final bool Function(String) localInstalled;
  final _remote = <String, Map<String, bool>>{};

  void update(String node, List<Map<String, dynamic>> inventory) {
    _remote[node] = {
      for (final engine in inventory)
        if (engine['coreId'] case final String coreId)
          coreId: engine['installed'] == true,
    };
  }

  bool allows(List<String> route, String core) =>
      (route.length == 1 || NodeRouting.supportsProxyCascade(core)) &&
      (route.first == Connection.localNode ||
          _remote[route.first]?.containsKey(core) == true);

  bool installed(List<String> route, String core) =>
      route.first == Connection.localNode
      ? localInstalled(core)
      : _remote[route.first]?[core] == true;
}
