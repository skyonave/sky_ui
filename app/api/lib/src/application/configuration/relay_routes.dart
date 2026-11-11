import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../engines/managed_core.dart';
import '../../shared/api_exception.dart';
import '../access/records.dart';
import '../contracts/configuration_codec.dart';

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

class RelayState {
  const RelayState(this.hash, this.running);
  final String hash;
  final bool running;
}

class RelayChange {
  const RelayChange(
    this.node,
    this.previous,
    this.configuration,
    this.ports,
    this.udpPorts,
  );
  final String node, previous, configuration;
  final Set<int> ports, udpPorts;
}

class RelayRoutes {
  RelayRoutes(this.transport, {required this.allowNew, this.localRelayAddress});
  final RelayTransport transport;
  final bool allowNew;
  final String? localRelayAddress;
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
        input.coreId != 'mihomo' ||
        input.protocolId != 'vless' ||
        nodes.length == 1 && nodes.single == _local) {
      throw const ApiException('route_invalid', status: 422);
    }
    for (final node in nodes) {
      address(data, node);
    }
    if (jsonEncode(old?.value.route) == jsonEncode(nodes)) {
      return {
        for (final entry in old!.secrets.entries)
          if (entry.key.startsWith('relay:')) entry.key: entry.value,
      };
    }
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
    for (var i = 0; i < nodes.length - 1; i++) {
      final source = await _ip(_relayAddress(data, nodes[i]));
      final destination = await _ip(_relayAddress(data, nodes[i + 1]));
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

  PanelData project(PanelData data, String node, String instance) {
    final connections = data.connections
        .where((c) => c.value.ingress == node && c.value.instanceId == instance)
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
          : {
              instance: {
                '_baseline': '{"mode":"rule","log-level":"info"}',
                'logLevel': 'info',
                'blockPrivate': 'true',
                'accessRules': '[]',
                'dnsMode': 'existing',
              },
            },
      relays: [
        for (final c in data.listeningConnections)
          if (c.value.instanceId == instance)
            for (var i = 0; i < c.value.route.length - 1; i++)
              if (c.value.route[i] == node || c.value.route[i + 1] == node)
                RelayLink(
                  connectionId: c.value.id,
                  index: i,
                  destination: c.secrets['relay:destination:$i']!,
                  source: c.secrets['relay:source:$i']!,
                  port: int.parse(c.secrets['relay:port:$i']!),
                  password: c.secrets['relay:key:$i']!,
                  inbound: c.value.route[i + 1] == node,
                  nextIndex: i + 2 < c.value.route.length ? i + 1 : null,
                ),
      ],
    );
  }

  Future<List<RelayChange>> changes(
    PanelData before,
    PanelData after,
    ConfigurationCodec codec,
    ManagedCore core,
  ) async {
    final nodes = <String>{
      for (final c in [...after.connections, ...before.connections])
        ...c.value.route.reversed.where((node) => node != _local),
    };
    final result = <RelayChange>[];
    for (final node in nodes) {
      final old = project(before, node, core.id);
      final next = project(after, node, core.id);
      String compile(PanelData data) =>
          data.listeningConnections.isEmpty && data.relays.isEmpty
          ? _base
          : codec.compile(data, core, _base);
      final previous = compile(old);
      final candidate = compile(next);
      if (candidate == previous) continue;
      if (candidate.length > 512 * 1024) {
        throw const ApiException('route_configuration_too_large', status: 422);
      }
      final state = await transport.inspect(node);
      if (state.hash != digest(previous)) {
        throw const ApiException(
          'route_configuration_out_of_sync',
          status: 409,
        );
      }
      await transport.validate(node, candidate);
      result.add(
        RelayChange(
          node,
          state.hash,
          candidate,
          {
            for (final c in next.listeningConnections) c.value.port!,
            for (final link in next.relays)
              if (link.inbound) link.port,
          },
          {
            for (final link in next.relays)
              if (link.inbound) link.port,
          },
        ),
      );
    }
    return result;
  }

  Future<void> verifyNewLinks(PanelData before, PanelData after) async {
    final old = {for (final c in before.listeningConnections) c.value.id: c};
    for (final c in after.listeningConnections) {
      final previous = old[c.value.id];
      for (var i = 0; i < c.value.route.length - 1; i++) {
        final port = c.secrets['relay:port:$i']!;
        if (previous?.secrets['relay:port:$i'] == port) continue;
        final destination = c.secrets['relay:destination:$i']!;
        try {
          if (c.value.route[i] == _local) {
            final socket = await Socket.connect(
              destination,
              int.parse(port),
              timeout: const Duration(seconds: 4),
            );
            socket.destroy();
          } else {
            await transport.probe(
              c.value.route[i],
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
