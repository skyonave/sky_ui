import 'dart:convert';

import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/application/configuration/relay_routes.dart';
import 'package:sky_ui_api/src/application/configuration/transaction.dart';
import 'package:sky_ui_api/src/application/engines/registry.dart';
import 'package:sky_ui_api/src/application/logs/panel_log.dart';
import 'package:sky_ui_api/src/engines/proxy/configuration.dart';
import 'package:sky_ui_api/src/engines/amnezia/configuration.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';

import 'core_manager_test.dart' show FakeAdapter, FakeSupervisor;
import 'relay_routes_test.dart'
    show RelayFixture, TransactionRepository, UninstalledConfiguration;

class EnginesTransport extends RelayFixture implements EngineRelayTransport {
  final documents = <(String, String), String>{};
  final backups = <(String, String), String>{};
  final restored = <(String, String)>[];
  final legacyRestored = <String>[];
  String? failEngine;
  bool failRestore = false;
  bool legacyMihomo = false;
  @override
  Future<Set<int>> occupiedPorts(String node) async => {22};
  String baseline(String engine) => switch (engine) {
    'mihomo' => RelayFixture.base,
    'amneziawg' => '{"version":"3.1","interfaces":[]}\n',
    _ => '{}\n',
  };
  @override
  Future<RelayState> inspectEngine(String node, String engine) async =>
      RelayState(
        digest(documents[(node, engine)] ?? baseline(engine)),
        true,
        extendedUdp: true,
        engineScoped: engine != 'mihomo' || !legacyMihomo,
      );
  @override
  Future<void> validateEngine(
    String node,
    String engine,
    String configuration,
  ) async {
    expect(jsonDecode(configuration), isA<Map>());
  }

  @override
  Future<void> publishEngine(
    String node,
    String engine,
    String transaction,
    String previous,
    String configuration,
    Set<int> ports,
    Set<int> udpPorts,
  ) async {
    expect((await inspectEngine(node, engine)).hash, previous);
    backups[(node, engine)] = documents[(node, engine)] ?? baseline(engine);
    documents[(node, engine)] = configuration;
    if (engine == failEngine)
      throw const ApiException('server_operation_failed');
  }

  @override
  Future<void> rollbackEngine(
    String node,
    String engine,
    String transaction,
  ) async {
    restored.add((node, engine));
    if (failRestore) throw const ApiException('server_ssh_failed');
    if (backups.remove((node, engine)) case final previous?)
      documents[(node, engine)] = previous;
  }

  @override
  Future<void> rollback(String node, String transaction) async {
    legacyRestored.add(node);
    if (failRestore) throw const ApiException('server_ssh_failed');
    if (backups.remove((node, 'mihomo')) case final previous?)
      documents[(node, 'mihomo')] = previous;
  }
}

void main() {
  final cores = {
    for (final id in ['mihomo', 'sing-box', 'xray', 'amneziawg'])
      id: ManagedCore(
        id: id == 'mihomo' ? 'primary' : id,
        coreId: id,
        service: 'fixture-$id',
        binary: '/not-installed/$id',
        directory: '/unused',
        configuration: '/unused/$id',
        controller: Uri.parse('http://127.0.0.1:19090'),
        secret: '',
      ),
  };
  final codecs = <String, ConfigurationCodec>{
    'mihomo': MihomoConfiguration(),
    'amneziawg': AmneziaConfiguration(),
    for (final id in ['sing-box', 'xray'])
      id: ProxyConfiguration(
        id,
        core: cores[id]!,
        supervisor: FakeSupervisor(),
      ),
  };
  Future<PanelData> populated() async {
    final data = PanelData(serverName: 'Panel', address: '192.0.2.10');
    data.recipients.add(
      const StoredRecipient(id: 'u', name: 'User', enabled: true, token: 't'),
    );
    var port = 35000;
    for (final entry in codecs.entries) {
      final engine = entry.key, codec = entry.value;
      final protocol = engine == 'amneziawg' ? 'amneziawg' : 'vless';
      final draft = Connection(
        id: 'c_$engine',
        name: engine,
        coreId: engine,
        instanceId: cores[engine]!.id,
        protocolId: protocol,
        port: ++port,
        route: const ['entry'],
        settings: {
          if (protocol == 'vless') ...{
            'security': 'REALITY',
            'serverName': 'www.kernel.org',
          },
        },
        routing: const {
          'entry': NodeRouting(
            rules: [RoutingRule('cidr', '192.0.2.0/24', 'block')],
          ),
        },
      );
      final connection = Connection.fromJson({
        ...draft.toJson(),
        'settings': codec.validateSettings(draft),
      });
      final stored = StoredConnection(
        connection,
        await codec.connectionSecrets(connection),
      );
      data.connections.add(stored);
      final credentials = await codec.grantCredentials(stored);
      data.grants.add(
        AccessGrant(
          id: 'g_$engine',
          recipientId: 'u',
          connectionId: connection.id,
          credentials: codec is GrantAllocator
              ? (codec as GrantAllocator).allocateGrant(
                  data,
                  stored,
                  credentials,
                )
              : credentials,
        ),
      );
    }
    return data;
  }

  ConfigurationTransaction recovering(
    TransactionRepository repository,
    EnginesTransport transport,
  ) {
    final managers = {
      for (final core in cores.values)
        core.id: CoreManager(
          core: core,
          adapters: {core.coreId: FakeAdapter()},
          supervisor: FakeSupervisor(),
          stateDirectory: '',
        ),
    };
    return ConfigurationTransaction(
      registry: EngineRegistry(
        primary: managers['primary']!,
        managers: managers,
        codecs: codecs,
      ),
      repository: repository,
      files: UninstalledConfiguration(),
      log: PanelLog(),
      routes: RelayRoutes(transport, allowNew: true),
    );
  }

  for (final legacyMihomo in [false, true])
    test(
      'persisted recovery retains ${legacyMihomo ? 'legacy' : 'native'} Mihomo undo after restart',
      () async {
        final transport = EnginesTransport()
          ..failEngine = 'xray'
          ..failRestore = true
          ..legacyMihomo = legacyMihomo;
        final repository = TransactionRepository(
          PanelData(serverName: 'Panel', address: '192.0.2.10'),
        );
        await expectLater(
          recovering(repository, transport).apply(0, (data) async {
            final next = await populated();
            data.connections.addAll(next.connections);
            data.recipients.addAll(next.recipients);
            data.grants.addAll(next.grants);
          }, () async {}),
          throwsA(isA<ApiException>()),
        );
        final pending = repository.pending!;
        final durable = jsonDecode(pending.previous) as Map;
        expect(durable['remote'], [
          for (final engine in cores.keys)
            if (legacyMihomo && engine == 'mihomo')
              'entry'
            else
              {'node': 'entry', 'engine': engine},
        ]);
        final restarted = EnginesTransport()
          ..documents.addAll(transport.documents)
          ..backups.addAll(transport.backups);
        final restoredRepository = TransactionRepository(repository.read())
          ..prepare(
            DeploymentIntent(
              pending.previous,
              pending.candidate,
              pending.wasRunning,
            ),
          );
        await recovering(restoredRepository, restarted).initialize();
        expect(restoredRepository.pending, isNull);
        expect(restarted.legacyRestored, legacyMihomo ? ['entry'] : isEmpty);
        expect(restarted.restored, [
          for (final engine in cores.keys.toList().reversed)
            if (!legacyMihomo || engine != 'mihomo') ('entry', engine),
        ]);
        for (final entry in restarted.documents.entries)
          expect(entry.value, restarted.baseline(entry.key.$2));
      },
    );

  test(
    'legacy pending intent retains legacy undo after a node upgrade',
    () async {
      final transport = EnginesTransport();
      final intent = jsonEncode({
        'skyUiDeployment': 2,
        'instances': {},
        'transaction': 'tx_legacy',
        'remote': ['entry'],
      });
      final repository = TransactionRepository(
        PanelData(serverName: 'Panel', address: '192.0.2.10'),
      )..prepare(DeploymentIntent(intent, intent, false));
      await recovering(repository, transport).initialize();
      expect(repository.pending, isNull);
      expect(transport.legacyRestored, ['entry']);
      expect(transport.restored, isEmpty);
    },
  );

  test(
    'all remote engine documents remain separate and do not need local binaries',
    () async {
      final transport = EnginesTransport(),
          routes = RelayRoutes(EnginesTransport(), allowNew: true);
      final after = await populated(),
          before = PanelData(serverName: 'Panel', address: '192.0.2.10');
      final changes = await routes.changes(
        before,
        after,
        codecs['mihomo']!,
        cores['mihomo']!,
        codecs: codecs,
        cores: cores.values,
      );
      expect(changes.map((c) => c.engine).toSet(), codecs.keys.toSet());
      for (final change in changes) {
        expect(change.node, 'entry');
        expect(change.previous, digest(transport.baseline(change.engine)));
        expect(change.configuration, contains('192.0.2.0/24'));
        expect(change.ports.length + change.udpPorts.length, 1);
        expect(
          routes.project(after, 'local', cores[change.engine]!.id).connections,
          isEmpty,
        );
      }
      final awg =
          jsonDecode(
                changes
                    .firstWhere((c) => c.engine == 'amneziawg')
                    .configuration,
              )
              as Map;
      expect((awg['interfaces'] as List).single['peers'], hasLength(1));
    },
  );

  test(
    'partial multi-engine remote deployment rolls back every engine on the node',
    () async {
      final transport = EnginesTransport()..failEngine = 'xray';
      final repo = TransactionRepository(
        PanelData(serverName: 'Panel', address: '192.0.2.10'),
      );
      final managers = {
        for (final core in cores.values)
          core.id: CoreManager(
            core: core,
            adapters: {core.coreId: FakeAdapter()},
            supervisor: FakeSupervisor(),
            stateDirectory: '',
          ),
      };
      final transaction = ConfigurationTransaction(
        registry: EngineRegistry(
          primary: managers['primary']!,
          managers: managers,
          codecs: codecs,
        ),
        repository: repo,
        files: UninstalledConfiguration(),
        log: PanelLog(),
        routes: RelayRoutes(transport, allowNew: true),
      );
      await expectLater(
        transaction.apply(0, (data) async {
          final next = await populated();
          data.connections.addAll(next.connections);
          data.recipients.addAll(next.recipients);
          data.grants.addAll(next.grants);
        }, () async {}),
        throwsA(isA<ApiException>()),
      );
      expect(repo.revision, 0);
      expect(repo.pending, isNull);
      expect(repo.read().grants, isEmpty);
      expect(transport.restored.toSet(), {
        for (final id in codecs.keys) ('entry', id),
      });
      for (final entry in transport.documents.entries)
        expect(entry.value, transport.baseline(entry.key.$2));
    },
  );

  test(
    'remote ingress relays stay in the ingress engine, transit uses Mihomo',
    () async {
      final routes = RelayRoutes(EnginesTransport(), allowNew: true);
      final data = await populated();
      final existing = data.connections.firstWhere(
        (c) => c.value.coreId == 'xray',
      );
      final value = existing.value.copyWith(route: const ['entry', 'exit']);
      data.connections
        ..clear()
        ..add(
          StoredConnection(value, {
            ...existing.secrets,
            ...await routes.prepare(data, value, null),
          }),
        );
      expect(
        routes
            .project(data, 'entry', 'xray', engine: 'xray')
            .relays
            .single
            .inbound,
        isFalse,
      );
      expect(routes.project(data, 'entry', 'primary').relays, isEmpty);
      expect(
        routes.project(data, 'exit', 'primary').relays.single.inbound,
        isTrue,
      );
      final returnValue = value.copyWith(route: const ['entry', 'local']);
      data.connections
        ..clear()
        ..add(
          StoredConnection(returnValue, {
            ...existing.secrets,
            ...await routes.prepare(data, returnValue, null),
          }),
        );
      expect(
        routes.project(data, 'local', 'primary').relays.single.inbound,
        isTrue,
      );
      expect(
        routes.project(data, 'local', 'xray', engine: 'xray').relays,
        isEmpty,
      );
    },
  );
}
