import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:sky_ui_web/src/features/connections/connection_draft.dart';
import 'package:sky_ui_web/src/features/connections/route_engines.dart';
import 'package:sky_ui_web/src/shared/state/panel_store.dart';

void require(bool value, String message) {
  if (!value) throw StateError(message);
}

void main() {
  const transport = ProtocolField(
    'transport',
    kind: 'choice',
    group: 'transport',
    defaultValue: 'TCP',
    options: ['TCP', 'WebSocket'],
  );
  const security = ProtocolField(
    'security',
    kind: 'choice',
    group: 'security',
    defaultValue: 'REALITY',
    options: ['REALITY', 'TLS'],
  );
  const vless = ProtocolDefinition(
    'vless',
    'VLESS',
    [transport, security],
    clientFieldBindings: {'transport': 'transport', 'security': 'security'},
    exportRestrictions: [
      ClientExportRestriction(
        protocolIds: ['vless'],
        format: 'clash',
        when: {
          'transport': ['WebSocket'],
          'security': ['REALITY'],
        },
      ),
    ],
  );
  final store = PanelStore()
    ..protocols = {
      'xray': [vless],
      'mihomo': [vless],
    };
  var installed = false;
  final initial = ConnectionDraft(store: store, coreInstalled: (_) => false);
  require(
    initial.connectionStep == 'route' &&
        initial.connectionSteps.first == 'route' &&
        initial.route.join(',') == Connection.localNode &&
        initial.routeId.isEmpty,
    'Every new connection starts with the current-server route selected.',
  );
  initial.advanceConnection();
  require(
    initial.connectionStep == 'protocol',
    'Route selection must advance without selecting a protocol or core first.',
  );
  final draft = ConnectionDraft(store: store, coreInstalled: (_) => installed)
    ..selectedProtocol = 'vless'
    ..selectedCore = 'xray'
    ..draft = {
      'name': 'Personal',
      'port': '35001',
      'transport': 'TCP',
      'security': 'REALITY',
    };
  require(
    draft.connectionSteps.contains('core'),
    'Multiple engines require a choice.',
  );
  require(
    draft.connectionSteps.contains('dependency'),
    'Missing engine requires installation.',
  );
  installed = true;
  require(
    !draft.connectionSteps.contains('dependency'),
    'Installed engine must not require installation.',
  );
  draft.changeField(transport, 'WebSocket');
  require(
    draft.draft['security'] == 'TLS',
    'Transport change must select compatible masking.',
  );
  require(
    draft.draft['port'] == '35001',
    'Transport change must retain the chosen port.',
  );
  require(
    draft.blockedChoices(security).containsKey('REALITY'),
    'Unsupported pairing stays disabled.',
  );
  draft.connectionStep = 'parameters';
  draft.draft['port'] = '70000';
  draft.advanceConnection();
  require(
    draft.connectionStep == 'parameters' &&
        draft.connectionErrors['port'] != null,
    'Invalid port must block the review step.',
  );
  draft.draft['port'] = '35001';
  draft.advanceConnection();
  require(
    draft.connectionStep == 'review',
    'Valid parameters must reach review.',
  );
  final other = ConnectionDraft(store: store, coreInstalled: (_) => true);
  late ConnectionDraft routed;
  routed =
      ConnectionDraft(
          store: store,
          coreInstalled: (_) => true,
          engineAllowed: (id) =>
              routed.route.first == Connection.localNode || id == 'mihomo',
        )
        ..selectedProtocol = 'vless'
        ..selectedCore = 'xray'
        ..draft = {'name': 'Retained', 'port': '35001', 'security': 'REALITY'};
  final routeNodes = ['de'];
  final routePolicies = {'de': const NodeRouting(fallback: NodeRouting.direct)};
  routed.selectRoute(
    NamedRoute(
      id: 'remote',
      name: 'Germany',
      nodes: routeNodes,
      policies: routePolicies,
    ),
  );
  require(
    routed.routeId == 'remote' &&
        routed.route.single == 'de' &&
        routed.selectedCore == null &&
        routed.selectedProtocol == null &&
        routed.draft['port'] == '35001' &&
        routed.draft['name'] == 'Retained',
    'Changing route clears incompatible choices without losing the name or port.',
  );
  routeNodes.add('other');
  routePolicies.clear();
  require(
    routed.route.length == 1 && routed.routing.length == 1,
    'Route selection must not share mutable state with the named route editor.',
  );
  routed.selectRoute(null);
  require(
    routed.route.single == Connection.localNode &&
        routed.routeId.isEmpty &&
        routed.routing.isEmpty,
    'The current-server route remains available after choosing a remote route.',
  );
  routed
    ..editingId = 'existing'
    ..selectedProtocol = 'vless'
    ..selectedCore = 'xray'
    ..connectionStep = 'route';
  routed.advanceConnection();
  require(
    routed.connectionStep == 'parameters',
    'Editing the route returns to parameters without changing the existing core.',
  );
  final engines = ConnectionRouteEngines(
    localInstalled: (core) => core == 'mihomo',
  );
  require(
    !engines.allows(['de'], 'xray'),
    'Remote choices stay unavailable until their engine inventory is known.',
  );
  engines.update('de', [
    {'coreId': 'mihomo', 'installed': true},
    {'coreId': 'xray', 'installed': false},
    {'coreId': 'sing-box', 'installed': true},
    {'coreId': 'amneziawg', 'installed': true},
  ]);
  require(
    engines.allows(['de'], 'xray') && !engines.installed(['de'], 'xray'),
    'Supported missing remote engines can be chosen for installation.',
  );
  require(
    engines.allows(['de'], 'amneziawg') &&
        !engines.allows(['de', Connection.localNode], 'amneziawg'),
    'AWG is supported on a standalone remote server but not as a proxy cascade.',
  );
  require(
    engines.installed(['de', Connection.localNode], 'sing-box') &&
        !engines.installed([Connection.localNode, 'de'], 'sing-box'),
    'The ingress installation is independent from relay node order and local binaries.',
  );
  engines.update('legacy', [
    {'coreId': 'mihomo', 'installed': true},
  ]);
  require(
    !engines.allows(['legacy'], 'amneziawg'),
    'Legacy nodes cannot silently offer unsupported remote engines.',
  );
  final remote =
      ConnectionDraft(
          store: store,
          coreInstalled: (_) => true,
          engineAllowed: (id) => id == 'mihomo',
        )
        ..selectedProtocol = 'vless'
        ..selectedCore = 'mihomo'
        ..draft = {
          'name': 'Remote',
          'port': '35002',
          'transport': 'TCP',
          'security': 'REALITY',
        };
  require(
    remote.candidateEngines('vless').join(',') == 'mihomo',
    'Remote ingress must not offer an engine that the node cannot run.',
  );
  require(
    !remote.connectionSteps.contains('dependency') &&
        !remote.connectionSteps.contains('core'),
    'A remote-only route must not require a local engine installation.',
  );
  remote.connectionStep = 'core';
  remote.advanceConnection();
  require(
    remote.connectionStep == 'transport',
    'Remote ingress keeps the protocol configuration steps.',
  );
  require(
    other.draft.isEmpty && other.selectedProtocol == null,
    'A new constructor must not inherit another draft.',
  );
  store.protocols.remove('mihomo');
  require(
    !draft.connectionSteps.contains('core'),
    'A sole engine is implicit.',
  );
  const fixed = ProtocolDefinition(
    'shadowsocks',
    'Shadowsocks',
    [
      ProtocolField(
        'network',
        kind: 'choice',
        group: 'transport',
        defaultValue: 'TCP',
        options: ['TCP'],
      ),
    ],
    clientFieldBindings: {'transport': 'network'},
  );
  store.protocols['xray'] = [fixed];
  draft
    ..selectedProtocol = 'shadowsocks'
    ..connectionStep = 'core'
    ..draft = {'name': 'Proxy', 'port': '35002', 'network': 'TCP'};
  draft.advanceConnection();
  require(
    draft.connectionStep == 'parameters',
    'A fixed transport must not add a meaningless step.',
  );
  final snapshot = PanelSnapshot(
    revision: 1,
    connections: const [],
    recipients: const [],
    serverName: 'Panel',
    address: 'panel.example.com',
    synchronized: true,
    deliveryReady: true,
    protocols: const {},
    routeNodes: const {'de': 'Germany'},
    routeAddresses: const {'de': 'de.example.com', 'v6': '2001:db8::1'},
    remoteInstanceStates: const {'de/mihomo': 'ready'},
  );
  final endpoints = PanelStore()
    ..apply(PanelSnapshot.fromJson(snapshot.toJson()));
  const remoteConnection = Connection(
    id: 'endpoint',
    name: 'Endpoint',
    coreId: 'mihomo',
    protocolId: 'vless',
    port: 20141,
    route: ['de'],
  );
  require(
    endpoints.connectionEndpoint(remoteConnection) == 'de.example.com:20141',
    'Client endpoints must use the advertised domain, never the node display name.',
  );
  require(
    endpoints.ready(remoteConnection),
    'A verified running remote core is ready.',
  );
  for (final state in [
    'missing',
    'stopped',
    'failed',
    'unreachable',
    'unknown',
  ]) {
    endpoints.remoteInstanceStates['de/mihomo'] = state;
    require(
      !endpoints.ready(remoteConnection),
      'Remote $state cannot count as an active connection.',
    );
  }
  endpoints.remoteInstanceStates.clear();
  require(
    !endpoints.ready(remoteConnection),
    'An absent remote observation cannot inherit local readiness.',
  );
  final cascade = remoteConnection.copyWith(route: ['de', 'exit']);
  endpoints.remoteInstanceStates.addAll({
    'de/mihomo': 'ready',
    'exit/mihomo': 'stopped',
  });
  require(
    !endpoints.ready(cascade),
    'A running ingress cannot hide a stopped relay.',
  );
  endpoints.remoteInstanceStates['exit/mihomo'] = 'ready';
  require(
    endpoints.ready(cascade),
    'All running remote hops allow the connection.',
  );
  final localRelay = remoteConnection.copyWith(
    route: ['de', Connection.localNode],
  );
  require(
    !endpoints.ready(localRelay),
    'A remote ingress still requires its local relay.',
  );
  endpoints.instanceReadiness['primary'] = true;
  require(
    endpoints.ready(localRelay),
    'A running local relay completes the remote path.',
  );
  require(
    endpoints.endpointForNode('v6', 35001) == '[2001:db8::1]:35001' &&
        endpoints.endpointForNode(Connection.localNode, 35001) ==
            'panel.example.com:35001',
    'Endpoint formatting must preserve local addresses and IPv6 boundaries.',
  );
  final legacy = snapshot.toJson()..remove('routeAddresses');
  endpoints.apply(PanelSnapshot.fromJson(legacy));
  require(
    endpoints.connectionEndpoint(remoteConnection).isEmpty,
    'Older snapshots must not substitute a node name or ID for a missing address.',
  );
  print('Connection draft decisions and validation passed.');
}
