import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/application/configuration/relay_routes.dart';
import 'package:sky_ui_api/src/application/configuration/route_policy.dart';
import 'package:sky_ui_api/src/application/configuration/transaction.dart';
import 'package:sky_ui_api/src/application/engines/registry.dart';
import 'package:sky_ui_api/src/application/logs/panel_log.dart';
import 'package:sky_ui_api/src/application/subscriptions/subscription_service.dart';
import 'package:sky_ui_api/src/engines/mihomo/routing.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';

import 'core_manager_test.dart' show FakeAdapter, FakeSupervisor;

class RelayFixture implements RelayTransport {
  final configurations = <String, String>{};
  final hashes = <String, String>{};
  final undo = <String, String>{};
  final rolledBack = <String>[];
  String? failOn;
  static const base = '{"mode":"rule","log-level":"info","listeners":[]}\n';

  @override
  Map<String, ServerNode> nodes() => {
    for (final (id, host) in [
      ('entry', '192.0.2.11'),
      ('transit', '192.0.2.12'),
      ('exit', '192.0.2.13'),
    ])
      id: ServerNode(id: id, name: id, host: host, port: 22, publicKey: ''),
  };

  @override
  Future<RelayState> inspect(String node) async =>
      RelayState(hashes[node] ?? digest(base), true);

  @override
  Future<void> validate(String node, String configuration) async {
    configurations[node] = configuration;
  }

  @override
  Future<void> publish(
    String node,
    String transaction,
    String previous,
    String configuration,
    Set<int> ports,
    Set<int> udpPorts,
  ) async {
    expect((await inspect(node)).hash, previous);
    undo[node] = previous;
    hashes[node] = digest(configuration);
    if (node == failOn)
      throw const ApiException('server_operation_failed', status: 502);
  }

  @override
  Future<void> rollback(String node, String transaction) async {
    rolledBack.add(node);
    final old = undo.remove(node);
    if (old != null) hashes[node] = old;
  }

  @override
  Future<void> probe(String node, String destination, int port) async {}
}

class ReadRepository implements AccessRepository {
  ReadRepository(this.data);
  final PanelData data;
  @override
  PanelData read() => data;
  @override
  String? recipientForToken(String token) =>
      token == 'token' ? 'recipient' : null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TransactionRepository extends ReadRepository {
  TransactionRepository(super.data);
  @override
  DeploymentIntent? pending;
  @override
  int revision = 0;
  @override
  String? instanceHash(String id) => null;
  @override
  String? metadata(String key) => null;
  @override
  void prepare(DeploymentIntent intent) => pending = intent;
  @override
  void clearPending() => pending = null;
  @override
  void commit(
    PanelData next,
    String configuration, {
    Map<String, String> configurations = const {},
  }) {
    data.connections
      ..clear()
      ..addAll(next.connections);
    data.recipients
      ..clear()
      ..addAll(next.recipients);
    data.grants
      ..clear()
      ..addAll(next.grants);
    revision++;
    clearPending();
  }
}

class UninstalledConfiguration implements ConfigurationStore {
  @override
  Future<String?> read(ManagedCore core) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final native = Platform.environment['SKY_UI_MIHOMO_BINARY'];
  final codec = MihomoConfiguration();
  final core = ManagedCore(
    id: 'primary',
    coreId: 'mihomo',
    service: 'fixture',
    binary: native ?? '',
    directory: '',
    configuration: '',
    controller: Uri.parse('http://127.0.0.1:19090'),
    secret: '',
  );

  test(
    'partial remote activation rolls back before grants become visible',
    () async {
      final transport = RelayFixture()..failOn = 'entry';
      final routes = RelayRoutes(transport, allowNew: true);
      final repository = TransactionRepository(
        PanelData(serverName: 'panel', address: '192.0.2.10'),
      );
      final primary = CoreManager(
        core: core,
        adapters: {'mihomo': FakeAdapter()},
        supervisor: FakeSupervisor(),
        stateDirectory: '',
      );
      final transaction = ConfigurationTransaction(
        registry: EngineRegistry(
          primary: primary,
          managers: {'primary': primary},
          codecs: {'mihomo': codec},
        ),
        repository: repository,
        files: UninstalledConfiguration(),
        log: PanelLog(),
        routes: routes,
      );
      Future<void> update(PanelData data) async {
        const connection = Connection(
          id: 'cascade',
          name: 'Cascade',
          coreId: 'mihomo',
          protocolId: 'vless',
          port: 35443,
          route: ['entry', 'exit'],
          settings: {
            'transport': 'TCP',
            'security': 'REALITY',
            'serverName': 'example.com',
          },
        );
        final secret = await codec.connectionSecrets(connection);
        secret.addAll(await routes.prepare(data, connection, null));
        final record = StoredConnection(connection, secret);
        data.connections.add(record);
        data.recipients.add(
          const StoredRecipient(
            id: 'recipient',
            name: 'Recipient',
            enabled: true,
            token: 'token',
          ),
        );
        data.grants.add(
          AccessGrant(
            id: 'grant',
            recipientId: 'recipient',
            connectionId: 'cascade',
            credentials: await codec.grantCredentials(record),
          ),
        );
      }

      await expectLater(
        transaction.apply(0, update, () async {}),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'server_operation_failed',
          ),
        ),
      );
      expect(transport.rolledBack, ['entry', 'exit']);
      expect(transport.hashes.values.toSet(), {digest(RelayFixture.base)});
      expect(repository.pending, isNull);
      expect(repository.read().grants, isEmpty);
      transport.failOn = null;
      await transaction.apply(0, update, () async {});
      expect(repository.revision, 1);
      expect(repository.read().grants.single.connectionId, 'cascade');
    },
  );

  Future<void> verifyNativeRouting() async {
    final directory = await Directory.systemTemp.createTemp(
      'sky-ui-native-links-',
    );
    final processes = <Process>[];
    final origins = [
      for (var i = 0; i < 4; i++)
        await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    ];
    final [ordinary, shortcut, transit, blocked] = origins;
    for (final origin in origins) {
      origin.listen((request) async {
        request.response.write('sky-ui-relay-traffic');
        await request.response.close();
      });
    }
    Future<int> allocate() async {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      return port;
    }

    final ports = [for (var i = 0; i < 4; i++) await allocate()];
    RelayLink link(int index, bool inbound) => RelayLink(
      connectionId: 'fixture',
      index: index,
      destination: '127.0.0.1',
      source: '127.0.0.1',
      port: ports[index + 1],
      password: base64.encode(List<int>.filled(32, index + 1)),
      inbound: inbound,
      nextIndex: index == 0 ? 1 : null,
      targetNode: index == 0 ? 'transit' : 'exit',
      routing: !inbound
          ? null
          : index == 0
          ? NodeRouting(
              rules: [
                RoutingRule('port', '${transit.port}', NodeRouting.direct),
                RoutingRule('port', '${shortcut.port}', NodeRouting.block),
              ],
            )
          : NodeRouting(
              rules: [
                RoutingRule('port', '${blocked.port}', NodeRouting.block),
              ],
            ),
    );
    final logs = StringBuffer();
    try {
      for (var node = 2; node >= 0; node--) {
        final data = PanelData(
          serverName: 'test',
          address: '127.0.0.1',
          relays: [
            if (node > 0) link(node - 1, true),
            if (node < 2) link(node, false),
            if (node != 1) link(2, node == 2),
          ],
        );
        final config =
            jsonDecode(codec.compile(data, core, RelayFixture.base)) as Map;
        // Permit the isolated HTTP fixture while retaining predecessor ACLs.
        for (final rules in (config['sub-rules'] as Map? ?? {}).values) {
          (rules as List).removeWhere((rule) => '$rule'.startsWith('IP-CIDR'));
        }
        if (node == 0) {
          config['sub-rules'] ??= <String, Object?>{};
          (config['sub-rules'] as Map)['fixture-ingress'] = MihomoRouting.rules(
            NodeRouting(
              rules: [RoutingRule('port', '${shortcut.port}', 'node:exit')],
            ),
            link(0, false).name,
            [link(0, false), link(2, false)],
            'fixture',
          );
          (config['listeners'] as List).add({
            'name': 'fixture-client',
            'type': 'mixed',
            'listen': '127.0.0.1',
            'port': ports[0],
            'rule': 'fixture-ingress',
          });
        }
        final home = await Directory('${directory.path}/$node').create();
        final file = File('${home.path}/config.json');
        await file.writeAsString(jsonEncode(config));
        final process = await Process.start(native!, [
          '-d',
          home.path,
          '-f',
          file.path,
        ]);
        processes.add(process);
        process.stdout.transform(utf8.decoder).listen(logs.write);
        process.stderr.transform(utf8.decoder).listen(logs.write);
        var ready = false;
        SocketException? lastError;
        for (var attempt = 0; attempt < 30 && !ready; attempt++) {
          try {
            final socket = await Socket.connect(
              '127.0.0.1',
              ports[node],
              timeout: const Duration(milliseconds: 200),
            );
            socket.destroy();
            ready = true;
          } on SocketException catch (e) {
            lastError = e;
            await Future<void>.delayed(const Duration(milliseconds: 70));
          }
        }
        expect(ready, isTrue, reason: '$lastError\n$logs');
      }
      Future<String> request(HttpServer origin) async {
        final socket = await Socket.connect('127.0.0.1', ports[0]);
        try {
          socket.write(
            'GET http://127.0.0.1:${origin.port}/ HTTP/1.1\r\n'
            'Host: 127.0.0.1:${origin.port}\r\nConnection: close\r\n\r\n',
          );
          await socket.flush();
          try {
            return await utf8.decoder
                .bind(socket)
                .join()
                .timeout(const Duration(seconds: 3), onTimeout: () => '');
          } on SocketException {
            return '';
          }
        } finally {
          socket.destroy();
        }
      }

      expect(
        await request(ordinary),
        contains('sky-ui-relay-traffic'),
        reason: '$logs',
      );
      expect(await request(blocked), isNot(contains('sky-ui-relay-traffic')));
      expect(
        await request(shortcut),
        contains('sky-ui-relay-traffic'),
        reason: '$logs',
      );
      processes.first.kill();
      await processes.first.exitCode;
      expect(await request(ordinary), isNot(contains('sky-ui-relay-traffic')));
      expect(await request(shortcut), isNot(contains('sky-ui-relay-traffic')));
      expect(
        await request(transit),
        contains('sky-ui-relay-traffic'),
        reason: '$logs',
      );
    } finally {
      for (final process in processes.reversed) {
        process.kill();
        await process.exitCode;
      }
      for (final origin in origins) {
        await origin.close(force: true);
      }
      await directory.delete(recursive: true);
    }
  }

  test(
    'native mihomo routes and blocks traffic at different cascade nodes',
    verifyNativeRouting,
    skip: native == null || !Platform.isLinux,
  );

  test(
    'three-node route compiles, limits hop sources, and exports only ingress',
    () async {
      final transport = RelayFixture();
      final routes = RelayRoutes(transport, allowNew: true);
      final before = PanelData(serverName: 'panel', address: '192.0.2.10');
      final after = before.copy();
      const connection = Connection(
        id: 'cascade',
        name: 'Cascade',
        coreId: 'mihomo',
        protocolId: 'vless',
        port: 35443,
        route: ['entry', 'transit', 'exit'],
        settings: {
          'transport': 'TCP',
          'security': 'REALITY',
          'serverName': 'example.com',
        },
      );
      final secret = await codec.connectionSecrets(connection);
      secret.addAll(await routes.prepare(after, connection, null));
      final record = StoredConnection(connection, secret);
      after.connections.add(record);
      after.recipients.add(
        const StoredRecipient(
          id: 'recipient',
          name: 'Recipient',
          enabled: true,
          token: 'token',
        ),
      );
      after.grants.add(
        AccessGrant(
          id: 'grant',
          recipientId: 'recipient',
          connectionId: 'cascade',
          credentials: await codec.grantCredentials(record),
        ),
      );
      final changes = await routes.changes(before, after, codec, core);
      expect(changes.map((c) => c.node), ['exit', 'transit', 'entry']);
      expect(
        routes.project(after, Connection.localNode, core.id).connections,
        isEmpty,
      );
      expect(changes.last.ports, {35443});
      final entry = jsonDecode(transport.configurations['entry']!) as Map;
      final transit = jsonDecode(transport.configurations['transit']!) as Map;
      final exit = jsonDecode(transport.configurations['exit']!) as Map;
      expect((entry['proxies'] as List).single['server'], '192.0.2.12');
      expect((transit['proxies'] as List).single['server'], '192.0.2.13');
      expect(
        (transit['sub-rules'] as Map).values.single,
        contains('SRC-IP-CIDR,192.0.2.11/32,sky-ui/relay/cascade/1'),
      );
      expect(
        (exit['sub-rules'] as Map).values.single,
        contains('SRC-IP-CIDR,192.0.2.12/32,DIRECT'),
      );
      expect((exit['listeners'] as List).single['type'], 'shadowsocks');

      final primary = CoreManager(
        core: core,
        adapters: {'mihomo': FakeAdapter()},
        supervisor: FakeSupervisor(),
        stateDirectory: '',
      );
      final subscriptions = SubscriptionService(
        config: ServerConfig(
          port: 39242,
          webOrigin: Uri.parse('https://panel.example'),
          publicDirectory: '',
          dataDirectory: '',
          core: core,
        ),
        registry: EngineRegistry(
          primary: primary,
          managers: {},
          codecs: {'mihomo': codec},
        ),
        repository: ReadRepository(after),
        exporter: ClashExporter(),
        isBusy: () => false,
        isSynchronized: () async => true,
        routes: routes,
      );
      final share = await subscriptions.share('recipient');
      expect(share.subscriptionUrl, 'https://panel.example/s/token');
      for (final format in ['relink', 'clash', 'v2ray']) {
        final profile = await subscriptions.subscription(
          'token',
          format: format,
        );
        final output = format == 'v2ray'
            ? utf8.decode(base64.decode(profile))
            : profile;
        expect(output, contains('192.0.2.11'));
        expect(output, isNot(contains('192.0.2.12')));
        expect(output, isNot(contains(secret['relay:key:0']!)));
      }

      Future<void> validateNative(List<RelayChange> candidates) async {
        if (native == null) return;
        final dir = await Directory.systemTemp.createTemp(
          'sky-ui-relay-native-',
        );
        try {
          for (final change in candidates) {
            final file = File('${dir.path}/${change.node}.json');
            await file.writeAsString(change.configuration);
            final check = await Process.run(native, [
              '-t',
              '-d',
              dir.path,
              '-f',
              file.path,
            ]);
            expect(
              check.exitCode,
              0,
              reason: '${check.stdout}\n${check.stderr}',
            );
          }
        } finally {
          await dir.delete(recursive: true);
        }
      }

      await validateNative(changes);
      for (final change in changes) {
        transport.hashes[change.node] = digest(change.configuration);
      }
      Connection withRouting(Map<String, NodeRouting> routing) =>
          Connection.fromJson({
            ...connection.toJson(),
            'routing': routing.map(
              (node, policy) => MapEntry(node, policy.toJson()),
            ),
          });
      expect(
        () => RoutePolicy.validate(
          withRouting({'exit': const NodeRouting(fallback: 'node:entry')}),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'route_policy_invalid',
          ),
        ),
      );
      final routed = withRouting(
        RoutePolicy.validate(
          withRouting({
            'entry': const NodeRouting(
              rules: [
                RoutingRule('suffix', ' Example.COM ', 'node:exit'),
                RoutingRule('network', 'udp', NodeRouting.block),
              ],
            ),
            'transit': const NodeRouting(fallback: NodeRouting.direct),
            'exit': const NodeRouting(
              rules: [RoutingRule('cidr', '2001:db8::1', NodeRouting.block)],
            ),
          }),
        ),
      );
      final updated = after.copy();
      final routedSecrets = await routes.prepare(updated, routed, record);
      updated.connections[0] = StoredConnection(routed, {
        ...secret,
        ...routedSecrets,
      });
      expect(routedSecrets['relay:key:0'], secret['relay:key:0']);
      expect(routedSecrets['relay:key:1'], secret['relay:key:1']);
      final routedChanges = await routes.changes(after, updated, codec, core);
      expect(routedChanges.map((change) => change.node), [
        'exit',
        'transit',
        'entry',
      ]);
      final ingressRules =
          (jsonDecode(routedChanges.last.configuration) as Map)['sub-rules']
              as Map;
      expect(
        ingressRules.values.single,
        containsAllInOrder([
          'DOMAIN-SUFFIX,example.com,sky-ui/relay/cascade/10',
          'NETWORK,udp,REJECT',
          'MATCH,sky-ui/relay/cascade/0',
        ]),
      );
      final exitRules =
          (jsonDecode(routedChanges.first.configuration) as Map)['sub-rules']
              as Map;
      expect(
        exitRules['sky-ui/relay/cascade/10'],
        contains(
          'SUB-RULE,(SRC-IP-CIDR,192.0.2.11/32),sky-ui/relay/cascade/10/policy',
        ),
      );
      expect(exitRules['sky-ui/relay/cascade/10/policy'], [
        'IP-CIDR6,2001:db8::1/128,REJECT',
        'MATCH,DIRECT',
      ]);
      final draft = PanelData(serverName: 'panel', address: '192.0.2.10');
      final localIngress = Connection.fromJson({
        ...routed.toJson(),
        'route': [Connection.localNode, 'transit', 'exit'],
        'routing': {Connection.localNode: routed.routing['entry']!.toJson()},
      });
      final draftSecrets = await routes.prepare(draft, localIngress, null);
      draft.connections.add(
        StoredConnection(localIngress, {...secret, ...draftSecrets}),
      );
      final inactive = routes.project(draft, Connection.localNode, core.id);
      expect(inactive.relays, isEmpty);
      final validation = routes.project(
        draft,
        Connection.localNode,
        core.id,
        validationOnly: true,
      );
      final localConfig = codec.compile(
        validation,
        core,
        RelayFixture.base,
        validationOnly: true,
      );
      expect(
        localConfig,
        contains('DOMAIN-SUFFIX,example.com,sky-ui/relay/cascade/10'),
      );
      await validateNative([
        ...routedChanges,
        RelayChange('local', '', localConfig, const {}, const {}),
      ]);
      for (final change in routedChanges) {
        transport.hashes[change.node] = digest(change.configuration);
      }
      final restored = await routes.changes(updated, after, codec, core);
      expect(
        restored.map((c) => c.configuration),
        changes.map((c) => c.configuration),
      );
      for (final change in restored) {
        transport.hashes[change.node] = digest(change.configuration);
      }
      final removal = await routes.changes(after, before, codec, core);
      expect(removal, hasLength(3));
      expect(
        removal.every((item) => item.configuration == RelayFixture.base),
        isTrue,
      );
    },
  );

  test(
    'local node can relay and restores its legacy routing mode after removal',
    () async {
      final transport = RelayFixture();
      final routes = RelayRoutes(transport, allowNew: true);
      final data = PanelData(serverName: 'panel', address: '192.0.2.10');
      const connection = Connection(
        id: 'relay',
        name: 'Relay',
        coreId: 'mihomo',
        protocolId: 'vless',
        port: 35443,
        route: ['entry', Connection.localNode, 'exit'],
        shareable: false,
      );
      data.connections.add(
        StoredConnection(
          connection,
          await routes.prepare(data, connection, null),
        ),
      );
      final local = routes.project(data, Connection.localNode, core.id);
      expect(local.relays, hasLength(2));
      final compiled = codec.compile(
        local,
        core,
        '{"mode":"direct","rules":[],"listeners":[]}',
      );
      expect((jsonDecode(compiled) as Map)['mode'], 'rule');
      data.connections.clear();
      final cleared =
          jsonDecode(
                codec.compile(
                  routes.project(data, Connection.localNode, core.id),
                  core,
                  compiled,
                ),
              )
              as Map;
      expect(cleared['mode'], 'direct');
      expect(cleared['rules'], isEmpty);
      expect(cleared['listeners'], isEmpty);
    },
  );
}
