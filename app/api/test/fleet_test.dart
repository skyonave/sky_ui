import 'dart:convert';
import 'dart:io';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/engines/proxy/configuration.dart';
import 'package:sky_ui_api/src/engines/amnezia/configuration.dart';
import 'package:sky_ui_api/src/engines/proxy/adapter.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';
import 'core_manager_test.dart' show FakeAdapter, FakeSupervisor;

class FleetAdapter extends FakeAdapter {
  FleetAdapter(this.id);
  @override
  final String id;
}

class FleetSupervisor extends FakeSupervisor {
  bool failOnce = false;
  bool failStartAfterActivation = false;
  @override
  Future<void> execute(ManagedCore core, CoreOperation operation) async {
    if (failOnce && operation == CoreOperation.restart) {
      failOnce = false;
      throw const ApiException('service_failed');
    }
    await super.execute(core, operation);
    if (failStartAfterActivation && operation == CoreOperation.start) {
      failStartAfterActivation = false;
      throw const ApiException('service_failed');
    }
  }
}

class ProxyFixture extends ProxyConfiguration {
  ProxyFixture(super.coreId, {required super.supervisor, required super.core});
  @override
  Future<void> verifyRunning(PanelData data, ManagedCore core) async {}
  @override
  Future<void> preflight(
    PanelData before,
    PanelData after,
    bool running,
  ) async {}
}

void main() {
  late Directory root;
  late PanelRepository repository;
  late PanelService panel;
  late Map<String, CoreManager> managers;
  late Map<String, FleetSupervisor> supervisors;
  late Map<String, ProxyFixture> codecs;
  late ServerConfig config;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('sky-ui-fleet-');
    managers = {};
    supervisors = {};
    codecs = {};
    for (final id in ['xray', 'sing-box']) {
      final core = ManagedCore(
        id: id,
        coreId: id,
        service: 'sky-ui-$id.service',
        binary: '/unused',
        directory: root.path,
        configuration: '${root.path}/$id.json',
        controller: Uri.parse('http://127.0.0.1:0'),
        secret: '',
      );
      final supervisor = FleetSupervisor()..state = CoreProcessState.active;
      supervisors[id] = supervisor;
      managers[id] = CoreManager(
        core: core,
        adapters: {id: FleetAdapter(id)},
        supervisor: supervisor,
        stateDirectory: '${root.path}/instances',
      );
      codecs[id] = ProxyFixture(id, core: core, supervisor: supervisor);
      await File(core.configuration).writeAsString(
        codecs[id]!.compile(
          PanelData(serverName: 'test', address: 'example.com'),
          core,
          '',
        ),
      );
    }
    config = ServerConfig(
      port: 39242,
      webOrigin: Uri.parse('https://example.com'),
      publicDirectory: root.path,
      dataDirectory: root.path,
      core: managers['xray']!.core,
      requireOwnerAuth: false,
    );
    repository = PanelRepository(
      '${root.path}/panel.sqlite',
      defaultAddress: 'example.com',
    );
    panel = PanelService(
      configurationStore: ConfigurationFiles(config.dataDirectory),
      config: config,
      manager: managers['xray']!,
      additionalManagers: [managers['sing-box']!],
      repository: repository,
      codecs: codecs,
      exporter: ClashExporter(),
      portProbe: (_) async => true,
      additionalExporters: [V2RayExporter()],
    );
    await panel.initialize();
  });
  tearDown(() async {
    repository.close();
    await root.delete(recursive: true);
  });
  Future<Connection> connection(String core, int port) async =>
      (await panel.saveConnection(
        repository.revision,
        Connection(
          id: '',
          name: core,
          coreId: core,
          instanceId: core,
          protocolId: 'vless',
          port: port,
          settings: const {'serverName': 'www.kernel.org'},
        ),
      )).connections.last;

  test(
    'first enabled grant starts only its engine and respects manual stop',
    () async {
      final owner = managers['xray']!, supervisor = supervisors['xray']!;
      supervisor.state = CoreProcessState.inactive;
      final c = await connection('xray', 35517);
      expect(supervisor.calls, isEmpty);

      final result = await panel.saveRecipient(
        repository.revision,
        Recipient(id: '', name: 'fixture', connectionIds: [c.id]),
      );
      expect(supervisor.calls, ['start']);
      expect(owner.desired, CoreDesiredState.unknown);
      expect(supervisors['sing-box']!.calls, isEmpty);

      supervisor.state = CoreProcessState.inactive;
      await panel.restoreCore();
      expect(supervisor.calls, ['start', 'start']);

      await panel.executeCore(CoreOperation.stop, instanceId: 'xray');
      await panel.saveConnection(
        repository.revision,
        Connection.fromJson({...c.toJson(), 'name': 'renamed'}),
        id: c.id,
      );
      await panel.restoreCore();
      expect(supervisor.calls, ['start', 'start', 'stop']);
      expect(result.recipients, hasLength(1));
    },
  );

  test(
    'failed automatic activation restores configuration and stops the process',
    () async {
      final supervisor = supervisors['xray']!
        ..state = CoreProcessState.inactive
        ..failStartAfterActivation = true;
      final c = await connection('xray', 35517);
      final file = File(managers['xray']!.core.configuration);
      final previous = await file.readAsString();
      final revision = repository.revision;

      await expectLater(
        panel.saveRecipient(
          revision,
          Recipient(id: '', name: 'fixture', connectionIds: [c.id]),
        ),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'service_failed'),
        ),
      );
      expect(supervisor.calls, ['start', 'stop']);
      expect(supervisor.state, CoreProcessState.inactive);
      expect(await file.readAsString(), previous);
      expect(repository.revision, revision);
      expect(repository.pending, isNull);
      expect(repository.read().grants, isEmpty);
    },
  );
  test(
    'an absent unrelated engine does not normalize or block a connection save',
    () async {
      (managers['sing-box']!.adapter as FleetAdapter).available = false;
      const initial =
          '{"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}';
      await File(
        managers['sing-box']!.core.configuration,
      ).writeAsString(initial);
      await connection('xray', 35509);
      expect(
        await File(managers['sing-box']!.core.configuration).readAsString(),
        initial,
      );
      expect(supervisors['sing-box']!.calls, isEmpty);
      expect(await panel.isSynchronized(), true);
    },
  );
  test(
    'JSON engines advertise distinct native settings capabilities',
    () async {
      expect((await panel.snapshot()).settingsInstances.toSet(), {
        'xray',
        'sing-box',
      });
      final xray = await panel.coreSettings('xray'),
          sing = await panel.coreSettings('sing-box');
      expect(xray.fields.firstWhere((f) => f.id == 'resolvers').kind, 'lines');
      expect(sing.fields.firstWhere((f) => f.id == 'resolvers').kind, 'text');
      expect(
        xray.fields.firstWhere((f) => f.id == 'logLevel').options,
        contains('none'),
      );
      expect(
        sing.fields.firstWhere((f) => f.id == 'logLevel').options,
        contains('trace'),
      );
      expect(xray.values['logLevel'], 'warning');
      expect(sing.values['logLevel'], 'info');
      expect(repository.read().coreSettings, isEmpty);
    },
  );
  for (final id in ['xray', 'sing-box']) {
    test(
      '$id settings are isolated, survive connection edits and roll back on activation failure',
      () async {
        final other = id == 'xray' ? 'sing-box' : 'xray';
        final c = await connection(id, 35511);
        await panel.saveRecipient(
          repository.revision,
          Recipient(id: '', name: 'fixture', connectionIds: [c.id]),
        );
        final credentials = repository.read().grants.single.credentials;
        final foreign = await File(
          managers[other]!.core.configuration,
        ).readAsString();
        final foreignCalls = supervisors[other]!.calls.length;
        await panel.saveCoreSettings(repository.revision, id, {
          'blockPrivate': 'true',
          'logLevel': 'debug',
        });
        expect(repository.read().coreSettings.keys, [id]);
        expect(
          await File(managers[other]!.core.configuration).readAsString(),
          foreign,
        );
        expect(supervisors[other]!.calls.length, foreignCalls);
        final saved = await File(
          managers[id]!.core.configuration,
        ).readAsString();
        final revision = repository.revision;
        supervisors[id]!.failOnce = true;
        await expectLater(
          panel.saveCoreSettings(revision, id, {'logLevel': 'error'}),
          throwsA(isA<ApiException>()),
        );
        expect(
          await File(managers[id]!.core.configuration).readAsString(),
          saved,
        );
        expect(repository.read().coreSettings[id]!['logLevel'], 'debug');
        expect(repository.revision, revision);
        expect(repository.pending, isNull);
        await panel.saveConnection(
          repository.revision,
          Connection(
            id: c.id,
            name: 'edited',
            coreId: id,
            instanceId: id,
            protocolId: c.protocolId,
            port: c.port,
            settings: c.settings,
          ),
          id: c.id,
        );
        expect((await panel.coreSettings(id)).values['logLevel'], 'debug');
        final native =
            jsonDecode(
                  await File(managers[id]!.core.configuration).readAsString(),
                )
                as Map;
        expect(native['log'][id == 'xray' ? 'loglevel' : 'level'], 'debug');
        expect(repository.read().grants.single.credentials, credentials);
        expect(supervisors[other]!.calls.length, foreignCalls);
      },
    );
  }
  test(
    'explicit unsupported transport and masking values fail instead of becoming defaults',
    () {
      for (final settings in [
        {'transport': 'KCP'},
        {'transport': 'WebSocket', 'security': 'REALITY'},
      ]) {
        expect(
          () => codecs['xray']!.validateSettings(
            Connection(
              id: '',
              name: 'invalid',
              coreId: 'xray',
              protocolId: 'vless',
              port: 8443,
              settings: settings,
            ),
          ),
          throwsA(isA<ApiException>()),
        );
      }
    },
  );
  test(
    'Xray REALITY export enables the current mihomo handshake and preserves version compatibility',
    () async {
      final value = await connection('xray', 35508);
      await panel.saveRecipient(
        repository.revision,
        Recipient(id: '', name: 'person', connectionIds: [value.id]),
      );
      final data = repository.read();
      final native =
          jsonDecode(
                await File(managers['xray']!.core.configuration).readAsString(),
              )
              as Map;
      expect(
        native['inbounds'][0]['streamSettings']['realitySettings']['minClientVer'],
        '1.8.2',
      );
      final endpoint = codecs['xray']!.clientEndpoint(
        data.connections.single,
        data.grants.single,
        data.address,
      );
      final client = jsonDecode(ClashExporter().profile([endpoint])) as Map;
      expect(
        client['proxies'][0]['reality-opts']['support-x25519mlkem768'],
        true,
      );
    },
  );
  test('native Naive link uses its certificate hostname', () {
    final link = ShareUriCodec().links([
      const ClientEndpoint(
        id: 'g',
        name: 'naive',
        protocolId: 'naive',
        server: '192.0.2.1',
        port: 8443,
        settings: {
          'transport': 'HTTP/2',
          'security': 'TLS',
          'serverName': 'vpn.example.com',
        },
        credentials: {'username': 'person', 'password': 'fixture-password'},
      ),
    ]).single;
    expect(Uri.parse(link.uri).host, 'vpn.example.com');
  });
  test('AWG bounds and signature limits are enforced before deployment', () {
    final codec = AmneziaConfiguration();
    for (final settings in [
      {'awg.S4': '0'},
      {'awg.I1': '<r 9999>'},
      {'awg.I1': '<b 0xabc>'},
      {'dns': '::1'},
    ]) {
      expect(
        () => codec.validateSettings(
          Connection(
            id: '',
            name: 'awg',
            coreId: 'amneziawg',
            protocolId: 'amneziawg',
            port: 8443,
            settings: settings,
          ),
        ),
        throwsA(isA<ApiException>()),
      );
    }
    expect(
      AmneziaConfiguration.validSignature('<b 0x010203><r 12><rd 4><rc 8><t>'),
      true,
    );
  });
  test('native journal levels retain exact severity', () {
    expect(
      JsonProxyAdapter.logLevel('TRACE[0001] error in diagnostic payload'),
      'trace',
    );
    expect(JsonProxyAdapter.logLevel('WARN[0001] session failed'), 'warning');
    expect(
      JsonProxyAdapter.logLevel('2026/11/02 [Debug] connection closed'),
      'debug',
    );
    expect(JsonProxyAdapter.logLevel('native message', '3'), 'error');
  });
  test(
    'recipient revocation still updates running engines when another owning engine was removed',
    () async {
      final a = await connection('xray', 35506),
          b = await connection('sing-box', 35507);
      final users = await panel.saveRecipient(
        repository.revision,
        Recipient(id: '', name: 'person', connectionIds: [a.id, b.id]),
      );
      (managers['sing-box']!.adapter as FleetAdapter).available = false;
      supervisors['sing-box']!.state = CoreProcessState.inactive;
      await panel.saveRecipient(
        repository.revision,
        Recipient(
          id: users.recipients.single.id,
          name: 'person',
          enabled: false,
          connectionIds: [a.id, b.id],
        ),
        id: users.recipients.single.id,
      );
      expect(repository.read().recipients.single.enabled, false);
      expect(
        (jsonDecode(
              await File(managers['xray']!.core.configuration).readAsString(),
            )
            as Map)['inbounds'],
        isEmpty,
      );
      expect(await panel.isSynchronized(), true);
    },
  );
  test(
    'one instance serves multiple listeners; editing another engine does not restart it',
    () async {
      final a = await connection('xray', 35511),
          b = await connection('sing-box', 35512);
      await panel.saveRecipient(
        repository.revision,
        Recipient(id: '', name: 'person', connectionIds: [a.id, b.id]),
      );
      expect(supervisors['xray']!.calls, ['restart']);
      expect(supervisors['sing-box']!.calls, ['restart']);
      final primaryCalls = [...supervisors['xray']!.calls];
      final c = await connection('sing-box', 35513);
      final user = repository.read().recipients.single;
      await panel.saveRecipient(
        repository.revision,
        Recipient(
          id: user.id,
          name: 'person',
          connectionIds: [a.id, b.id, c.id],
        ),
        id: user.id,
      );
      expect(supervisors['xray']!.calls, primaryCalls);
      expect(
        (jsonDecode(
              await File(
                managers['sing-box']!.core.configuration,
              ).readAsString(),
            )
            as Map)['inbounds'],
        hasLength(2),
      );
      final snapshot = await panel.snapshot();
      expect(snapshot.instanceIds, {'xray': 'xray', 'sing-box': 'sing-box'});
      expect(snapshot.instanceReadiness.values.every((v) => v), true);
    },
  );
  test(
    'cross-engine revocation rolls back every changed file and database on failure',
    () async {
      final a = await connection('xray', 35521),
          b = await connection('sing-box', 35522);
      await panel.saveRecipient(
        repository.revision,
        Recipient(id: '', name: 'person', connectionIds: [a.id, b.id]),
      );
      final before = {
        for (final e in managers.entries)
          e.key: await File(e.value.core.configuration).readAsString(),
      };
      final revision = repository.revision,
          user = repository.read().recipients.single;
      supervisors['xray']!.failOnce = true;
      await expectLater(
        panel.saveRecipient(
          revision,
          Recipient(
            id: user.id,
            name: user.name,
            enabled: false,
            connectionIds: [a.id, b.id],
          ),
          id: user.id,
        ),
        throwsA(isA<ApiException>()),
      );
      expect(repository.revision, revision);
      expect(repository.read().recipients.single.enabled, true);
      expect(repository.pending, null);
      for (final e in managers.entries) {
        expect(
          await File(e.value.core.configuration).readAsString(),
          before[e.key],
        );
      }
    },
  );
  test(
    'durable multi-engine recovery restores both prior configurations',
    () async {
      final changes = <String, dynamic>{};
      for (final e in managers.entries) {
        final file = File(e.value.core.configuration),
            previous = await file.readAsString();
        changes[e.key] = {'previous': previous, 'wasRunning': true};
        await file.writeAsString('interrupted');
      }
      repository.prepare(
        DeploymentIntent(
          jsonEncode({'skyUiDeployment': 2, 'instances': changes}),
          '',
          true,
        ),
      );
      await panel.initialize();
      expect(repository.pending, null);
      for (final e in managers.entries) {
        expect(
          await File(e.value.core.configuration).readAsString(),
          changes[e.key]['previous'],
        );
      }
    },
  );
  test(
    'stopping an unrelated engine does not block another recipient subscription',
    () async {
      final a = await connection('xray', 35531);
      await panel.saveRecipient(
        repository.revision,
        Recipient(id: '', name: 'person', connectionIds: [a.id]),
      );
      await panel.executeCore(CoreOperation.stop, instanceId: 'sing-box');
      expect(
        (await panel.share(repository.read().recipients.single.id)).links,
        hasLength(1),
      );
    },
  );
  test(
    'new retired protocols are rejected without deleting existing records',
    () async {
      await expectLater(
        panel.saveConnection(
          repository.revision,
          const Connection(
            id: '',
            name: 'old',
            coreId: 'xray',
            instanceId: 'xray',
            protocolId: 'vmess',
            port: 35541,
          ),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'protocol_unavailable',
          ),
        ),
      );
      expect(repository.read().connections, isEmpty);
    },
  );
  test(
    'AWG 3.1 allocates distinct peers and exports only the recipient private key',
    () async {
      final codec = AmneziaConfiguration();
      final settings = codec.validateSettings(
        const Connection(
          id: '',
          name: 'awg',
          coreId: 'amneziawg',
          instanceId: 'amneziawg',
          protocolId: 'amneziawg',
          port: 35551,
        ),
      );
      final value = Connection(
        id: 'awg',
        name: 'awg',
        coreId: 'amneziawg',
        instanceId: 'amneziawg',
        protocolId: 'amneziawg',
        port: 35551,
        settings: settings,
      );
      final secrets = await codec.connectionSecrets(value),
          record = StoredConnection(value, secrets);
      final data = PanelData(
        serverName: '',
        address: 'example.com',
        connections: [record],
      );
      final first = codec.allocateGrant(
        data,
        record,
        await codec.grantCredentials(record),
      );
      data.grants.add(
        AccessGrant(
          id: 'g1',
          recipientId: 'u1',
          connectionId: 'awg',
          credentials: first,
        ),
      );
      final second = codec.allocateGrant(
        data,
        record,
        await codec.grantCredentials(record),
      );
      expect(first['address'], isNot(second['address']));
      final endpoint = codec.clientEndpoint(
        record,
        data.grants.single,
        'example.com',
      );
      final profile = ShareUriCodec().links([endpoint]).single;
      expect(profile.filename, endsWith('.conf'));
      expect(profile.content, contains('RandomTrailers = on'));
      expect(profile.content, contains('PrivateKey = ${first['privateKey']}'));
      expect(profile.content, isNot(contains(secrets['privateKey']!)));
      expect(secrets, await codec.connectionSecrets(value, previous: secrets));
    },
  );
}
