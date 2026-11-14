import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../engines/managed_core.dart';
import '../../shared/api_exception.dart';
import '../access/records.dart';
import '../contracts/configuration_codec.dart';
import 'route_policy.dart';

abstract interface class RelayTransport {
  Map<String, ServerNode> nodes();
  Future<RelayState> inspect(String node);
  Future<void> validate(String node, String configuration);
  Future<void> publish(
    String node,
    String transaction,
    String previous,
    String configuration,
    Set<int> ports,
    Set<int> udpPorts,
  );
  Future<void> rollback(String node, String transaction);
  Future<void> probe(String node, String destination, int port);
}

/// Versioned node workers keep each engine's configuration and undo slot separate.
abstract interface class EngineRelayTransport implements RelayTransport {
  Future<Set<int>> occupiedPorts(String node);
  Future<RelayState> inspectEngine(String node, String engine);
  Future<void> validateEngine(String node, String engine, String configuration);
  Future<void> publishEngine(
    String node,
    String engine,
    String transaction,
    String previous,
    String configuration,
    Set<int> ports,
    Set<int> udpPorts,
  );
  Future<void> rollbackEngine(String node, String engine, String transaction);
}

/// Last bounded observations, refreshed asynchronously without blocking snapshots.
abstract interface class CachedRelayReadiness {
  Map<String, String> cachedReadiness(
    Iterable<({String node, String engine})> engines,
  );
}

class RelayState {
  const RelayState(
    this.hash,
    this.running, {
    this.extendedUdp = false,
    this.installed = true,
    this.engineScoped = false,
  });
  final String hash;
  final bool running;
  final bool extendedUdp;
  final bool installed;
  final bool engineScoped;
}

class RelayChange {
  const RelayChange(
    this.node,
    this.previous,
    this.configuration,
    this.ports,
    this.udpPorts, {
    this.engine = 'mihomo',
    this.engineScoped = false,
  });
  final String node, previous, configuration;
  final Set<int> ports, udpPorts;
  final String engine;
  final bool engineScoped;
}

class RelayRoutes {
  RelayRoutes(
    this.transport, {
    required this.allowNew,
    this.localRelayAddress,
    this.relayInstanceId = 'primary',
  });
  final RelayTransport transport;
  final bool allowNew;
  final String? localRelayAddress;
  final String relayInstanceId;
  final _random = Random.secure();
  static const _local = Connection.localNode;
  static const _base = '{"mode":"rule","log-level":"info","listeners":[]}\n';

  Map<String, String> names(PanelData data) => {
    if (allowNew || data.connections.any((c) => c.value.route.isNotEmpty))
      _local: data.serverName,
    for (final node in transport.nodes().values)
      if (allowNew ||
          data.connections.any((c) => c.value.route.contains(node.id)))
        node.id: node.name,
  };

  ServerNode _node(String id) =>
      transport.nodes()[id] ??
      (throw const ApiException('route_node_missing', status: 409));

  String address(PanelData data, String node) {
    if (node == _local) return data.address;
    final remote = _node(node);
    return remote.endpoint ?? remote.host;
  }

  String _relayAddress(PanelData data, String node) {
    if (node == _local) return localRelayAddress ?? data.address;
    final remote = _node(node);
    return remote.relayAddress ?? remote.host;
  }

  Future<Map<String, String>> prepare(
    PanelData data,
    Connection input,
    StoredConnection? old,
  ) async {
    final nodes = input.route;
    if (nodes.isEmpty) return {};
    if ((!allowNew && jsonEncode(old?.value.route) != jsonEncode(nodes)) ||
        nodes.length > 8 ||
        nodes.toSet().length != nodes.length ||
        nodes.length > 1 && !NodeRouting.supportsProxyCascade(input.coreId) ||
        nodes.length == 1 && nodes.single == _local) {
      throw const ApiException('route_invalid', status: 422);
    }
    for (final node in nodes) {
      address(data, node);
    }
    final unchangedNodes = jsonEncode(old?.value.route) == jsonEncode(nodes);
    final reserved = <int>{
      if (input.port != null) input.port!,
      for (final c in data.connections) ...{
        if (c.value.port != null) c.value.port!,
        for (final e in c.secrets.entries)
          if (e.key.startsWith('relay:port:')) int.parse(e.value),
      },
      for (final g in data.grants)
        if (int.tryParse(g.credentials['port'] ?? '') case final port?) port,
    };
    final result = <String, String>{};
    for (final edge in RoutePolicy.edges(input)) {
      final i = edge.index;
      if (unchangedNodes && old!.secrets.containsKey('relay:port:$i')) {
        for (final field in ['port', 'source', 'destination', 'key']) {
          final key = 'relay:$field:$i';
          result[key] = old.secrets[key]!;
        }
        continue;
      }
      final source = await _ip(_relayAddress(data, nodes[edge.from]));
      final destination = await _ip(_relayAddress(data, nodes[edge.to]));
      if (source.contains(':') != destination.contains(':')) {
        throw const ApiException('route_address_unavailable', status: 422);
      }
      final offset = _random.nextInt(20000);
      final port = Iterable.generate(
        20000,
        (j) => 40000 + (offset + j) % 20000,
      ).where(reserved.add).firstOrNull;
      if (port == null) throw const ApiException('port_in_use', status: 409);
      result.addAll({
        'relay:port:$i': '$port',
        'relay:source:$i': source,
        'relay:destination:$i': destination,
        'relay:key:$i': base64.encode(
          List<int>.generate(32, (_) => _random.nextInt(256)),
        ),
      });
    }
    return result;
  }

  Future<String> _ip(String host) async {
    final literal = InternetAddress.tryParse(host);
    if (literal != null) return literal.address;
    try {
      final addresses = await InternetAddress.lookup(
        host,
      ).timeout(const Duration(seconds: 5));
      if (addresses.isNotEmpty) {
        return (addresses
                    .where((ip) => ip.type == InternetAddressType.IPv4)
                    .firstOrNull ??
                addresses.first)
            .address;
      }
    } on Exception {
      throw const ApiException('route_address_unavailable', status: 422);
    }
    throw const ApiException('route_address_unavailable', status: 422);
  }

  PanelData project(
    PanelData data,
    String node,
    String instance, {
    bool validationOnly = false,
    String? engine,
  }) {
    final connections = data.connections
        .where((c) => c.value.ingress == node && c.value.instanceId == instance)
        .map(
          (c) => node == _local
              ? c
              : StoredConnection(
                  c.value.copyWith(
                    routing: {
                      ...c.value.routing,
                      if (c.value.routing[node] case final policy?)
                        _local: policy,
                    },
                  ),
                  c.secrets,
                ),
        )
        .toList();
    final ids = connections.map((c) => c.value.id).toSet();
    return PanelData(
      serverName: data.serverName,
      address: data.address,
      connections: connections,
      recipients: data.recipients,
      grants: data.grants.where((g) => ids.contains(g.connectionId)).toList(),
      coreSettings: node == _local
          ? {
              if (data.coreSettings.containsKey(instance))
                instance: data.coreSettings[instance]!,
            }
          : (engine == null || engine == 'mihomo')
          ? {
              instance: {
                '_baseline': '{"mode":"rule","log-level":"info"}',
                'logLevel': 'info',
                'blockPrivate': 'true',
                'accessRules': '[]',
                'dnsMode': 'existing',
              },
            }
          : {},
      relays: [
        for (final c
            in validationOnly ? data.connections : data.listeningConnections)
          if ((c.value.ingress == node
                  ? c.value.instanceId
                  : relayInstanceId) ==
              instance)
            for (final edge in RoutePolicy.edges(c.value))
              if (c.value.route[edge.from] == node ||
                  c.value.route[edge.to] == node)
                RelayLink(
                  connectionId: c.value.id,
                  index: edge.index,
                  destination: c.secrets['relay:destination:${edge.index}']!,
                  source: c.secrets['relay:source:${edge.index}']!,
                  port: int.parse(c.secrets['relay:port:${edge.index}']!),
                  password: c.secrets['relay:key:${edge.index}']!,
                  inbound: c.value.route[edge.to] == node,
                  nextIndex: edge.to < c.value.route.length - 1
                      ? edge.to
                      : null,
                  targetNode: c.value.route[edge.to],
                  routing: c.value.route[edge.to] == node
                      ? c.value.routing[node]
                      : null,
                ),
      ],
    );
  }

  Future<List<RelayChange>> changes(
    PanelData before,
    PanelData after,
    ConfigurationCodec codec,
    ManagedCore core, {
    Map<String, ConfigurationCodec> codecs = const {},
    Iterable<ManagedCore> cores = const [],
  }) async {
    final nodes = <String>{
      for (final c in [...after.connections, ...before.connections])
        ...c.value.route.reversed.where((node) => node != _local),
    };
    final result = <RelayChange>[];
    for (final node in nodes) {
      for (final localCore in {
        core.id: core,
        for (final c in cores) c.id: c,
      }.values) {
        final engine = localCore.coreId;
        final native = codecs[engine] ?? (engine == core.coreId ? codec : null);
        if (native == null) continue;
        final directory = '/var/lib/sky-ui-node/engines/$engine';
        final remoteCore = ManagedCore(
          id: localCore.id,
          coreId: engine,
          service: 'sky-ui-node-$engine.service',
          binary:
              '/usr/local/libexec/sky-ui-node/cores/$engine/current/$engine',
          directory: engine == 'mihomo'
              ? '/var/lib/sky-ui-node/runtime'
              : '$directory/runtime',
          configuration: engine == 'mihomo'
              ? '/var/lib/sky-ui-node/config.json'
              : '$directory/config.json',
          controller: localCore.controller,
          secret: localCore.secret,
        );
        final old = project(before, node, localCore.id, engine: engine);
        final next = project(after, node, localCore.id, engine: engine);
        final base = switch (engine) {
          'mihomo' => _base,
          'amneziawg' => '{"version":"3.1","interfaces":[]}\n',
          _ => '{}\n',
        };
        void settings(PanelData data) {
          if (native is RoutingBaselineCodec && engine != 'mihomo')
            data.coreSettings[remoteCore.id] = (native as RoutingBaselineCodec)
                .initialRoutingSettings(base);
        }

        settings(old);
        settings(next);
        String compile(PanelData data) =>
            (engine == 'amneziawg'
                    ? data.connections.isEmpty
                    : data.listeningConnections.isEmpty) &&
                data.relays.isEmpty
            ? base
            : native.compile(data, remoteCore, base);
        final previous = compile(old);
        final candidate = compile(next);
        if (candidate == previous) continue;
        if (candidate.length > 512 * 1024) {
          throw const ApiException(
            'route_configuration_too_large',
            status: 422,
          );
        }
        final scoped = transport is EngineRelayTransport
            ? transport as EngineRelayTransport
            : null;
        if (scoped == null && engine != 'mihomo')
          throw const ApiException('server_upgrade_required', status: 409);
        final state =
            await (scoped?.inspectEngine(node, engine) ??
                transport.inspect(node));
        if (!state.installed)
          throw const ApiException('binary_missing', status: 409);
        if (state.hash != digest(previous)) {
          throw const ApiException(
            'route_configuration_out_of_sync',
            status: 409,
          );
        }
        final ports = native is RelayBindingsCodec
            ? (native as RelayBindingsCodec).relayIngressBindings(next)
            : _bindings(next, engine);
        if (!state.extendedUdp &&
            ports.udp.isNotEmpty &&
            (ports.tcp.isEmpty ||
                ports.udp.any((p) => p < 40000 || p >= 60000))) {
          throw const ApiException('route_node_protocol', status: 409);
        }
        // Validate enabled drafts too, before the first recipient is granted.
        final validationData = project(
          after,
          node,
          localCore.id,
          engine: engine,
          validationOnly: true,
        );
        settings(validationData);
        final validation = native.compile(
          validationData,
          remoteCore,
          base,
          validationOnly: true,
        );
        await (scoped?.validateEngine(node, engine, validation) ??
            transport.validate(node, validation));
        if (validation != candidate)
          await (scoped?.validateEngine(node, engine, candidate) ??
              transport.validate(node, candidate));
        result.add(
          RelayChange(
            node,
            state.hash,
            candidate,
            ports.tcp,
            ports.udp,
            engine: engine,
            engineScoped: engine != 'mihomo' || state.engineScoped,
          ),
        );
      }
    }
    return result;
  }

  ({Set<int> tcp, Set<int> udp}) _bindings(PanelData data, String engine) {
    final tcp = <int>{}, udp = <int>{};
    for (final c
        in engine == 'amneziawg'
            ? data.connections.where((c) => c.value.enabled)
            : data.listeningConnections) {
      final ports = {
        for (final g in data.activeGrants(c.value.id))
          int.tryParse(g.credentials['port'] ?? '') ?? c.value.port!,
        if (engine == 'amneziawg') c.value.port!,
      };
      final datagrams =
          engine == 'amneziawg' ||
          {'tuic', 'hysteria2'}.contains(c.value.protocolId) ||
          c.value.settings['transport'] == 'HTTP/3';
      (datagrams ? udp : tcp).addAll(ports);
      if (c.value.protocolId == 'shadowsocks') udp.addAll(ports);
    }
    return (tcp: tcp, udp: udp);
  }

  Future<void> verifyNewLinks(PanelData before, PanelData after) async {
    final old = {for (final c in before.listeningConnections) c.value.id: c};
    for (final c in after.listeningConnections) {
      final previous = old[c.value.id];
      for (final edge in RoutePolicy.edges(c.value)) {
        final i = edge.index;
        final port = c.secrets['relay:port:$i']!;
        if (previous?.secrets['relay:port:$i'] == port) continue;
        final destination = c.secrets['relay:destination:$i']!;
        try {
          if (c.value.route[edge.from] == _local) {
            final socket = await Socket.connect(
              destination,
              int.parse(port),
              timeout: const Duration(seconds: 4),
            );
            socket.destroy();
          } else {
            await transport.probe(
              c.value.route[edge.from],
              destination,
              int.parse(port),
            );
          }
        } on Exception {
          throw const ApiException('route_link_unreachable', status: 502);
        }
      }
    }
  }
}
