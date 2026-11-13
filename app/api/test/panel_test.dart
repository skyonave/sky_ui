import 'dart:convert';
import 'dart:io';
import 'package:dart_frog/dart_frog.dart';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/engines/amnezia/configuration.dart';
import 'package:sky_ui_api/src/application/configuration/relay_routes.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'core_manager_test.dart' show FakeAdapter, FakeSupervisor;
import 'relay_routes_test.dart' show RelayFixture;

class Adapter extends FakeAdapter {
  @override
  String get id => 'mihomo';
  bool invalidCandidate = false;
  @override
  Future<void> validate(ManagedCore core) async {
    if (invalidCandidate &&
        File(
          core.configuration,
        ).parent.parent.path.endsWith('${Platform.pathSeparator}staging'))
      throw const ApiException('configuration_invalid', status: 422);
    await super.validate(core);
  }
}

class Supervisor extends FakeSupervisor {
  int failures = 0;
  @override
  Future<void> execute(ManagedCore core, CoreOperation operation) async {
    if (failures > 0 && operation != CoreOperation.stop) {
      failures--;
      calls.add('failed_restart');
      state = CoreProcessState.failed;
      throw const ApiException('service_failed');
    }
    await super.execute(core, operation);
  }
}

class Codec extends MihomoConfiguration {
  int failedProbes = 0;
  @override
  Future<void> verifyRunning(PanelData data, ManagedCore core) async {
    if (failedProbes > 0) {
      failedProbes--;
      throw const ApiException('listener_not_ready');
    }
  }
}

class AwgCodec extends AmneziaConfiguration {
  @override
  Future<void> verifyRunning(PanelData data, ManagedCore core) async {}
}

void main() {
  late Directory directory;
  late PanelRepository repository;
  late PanelService panel;
  late CoreManager manager;
  late Adapter adapter;
  late Supervisor supervisor;
  late Codec codec;
  late ServerConfig config;
  late int freePort;
  late File native;
  const baseline =
      '{"mode":"direct","listeners":[],"secret":"controller-only-secret"}\n';
  Connection input({
    String protocol = 'vless',
    Map<String, String> settings = const {},
  }) => Connection(
    id: '',
    name: 'Основной',
    coreId: 'mihomo',
    protocolId: protocol,
    port: freePort,
    settings: settings,
  );
  PanelService service({
    List<CoreManager> additionalManagers = const [],
    RelayRoutes? routes,
  }) => PanelService(
    routes: routes,
    configurationStore: ConfigurationFiles(config.dataDirectory),
    config: config,
    manager: manager,
    repository: repository,
    codecs: {'mihomo': codec, 'amneziawg': AwgCodec()},
    exporter: ClashExporter(),
    portProbe: (_) async => true,
    additionalExporters: [V2RayExporter()],
    additionalManagers: additionalManagers,
  );
  Future<PanelSnapshot> connection() =>
      panel.saveConnection(repository.revision, input());
  Future<PanelSnapshot> recipient(
    String connectionId, {
    String name = 'Друг',
  }) => panel.saveRecipient(
    repository.revision,
    Recipient(id: '', name: name, connectionIds: [connectionId]),
  );
  Future<String> token(String id) async => Uri.parse(
    (await panel.share(id)).subscriptionUrl,
  ).pathSegments.last.split('.').first;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sky-ui-panel-');
    native = File('${directory.path}/config.yaml');
    await native.writeAsString(baseline);
    final socket = await ServerSocket.bind('127.0.0.1', 0);
    freePort = socket.port;
    await socket.close();
    final core = ManagedCore(
      id: 'primary',
      coreId: 'mihomo',
      service: 'sky-ui-mihomo.service',
      binary: '/unused',
      directory: directory.path,
      configuration: native.path,
      controller: Uri.parse('http://127.0.0.1:19090'),
      secret: 'controller-only-secret',
    );
    adapter = Adapter();
    supervisor = Supervisor()..state = CoreProcessState.active;
    codec = Codec();
    manager = CoreManager(
      core: core,
      adapters: {'mihomo': adapter},
      supervisor: supervisor,
      stateDirectory: '${directory.path}/instances',
      readyTimeout: const Duration(milliseconds: 30),
    );
    config = ServerConfig(
      requireOwnerAuth: false,
      port: 39242,
      webOrigin: Uri.parse('https://panel.example.net'),
      publicDirectory: directory.path,
      dataDirectory: directory.path,
      core: core,
    );
    repository = PanelRepository(
      '${directory.path}/panel.sqlite',
      defaultAddress: 'panel.example.net',
    );
    panel = service();
    await panel.initialize();
  });
  test(
    'remote-only named route serves clients without a local engine',
    () async {
      final transport = RelayFixture();
      final routes = RelayRoutes(transport, allowNew: true);
      adapter.available = false;
      supervisor.state = CoreProcessState.inactive;
      panel = service(routes: routes);
      final baselineConfig = await native.readAsString();
      final route = (await panel.saveNamedRoute(
        repository.revision,
        const NamedRoute(id: '', name: 'Remote', nodes: ['entry']),
      )).routes.single;
      final c = (await panel.saveConnection(
        repository.revision,
        input().copyWith(routeId: route.id),
      )).connections.single;
      expect(c.route, ['entry']);
      final users = await recipient(c.id);
      expect(transport.configurations['entry'], contains('"port": $freePort'));
      expect(await native.readAsString(), baselineConfig);
      expect(supervisor.calls, isEmpty);
      final share = await panel.share(users.recipients.single.id);
      expect(share.links.single.uri, contains('192.0.2.11'));
      final oldGrants = repository.read().grants.single.credentials;
      await panel.saveNamedRoute(
        repository.revision,
        NamedRoute(id: route.id, name: route.name, nodes: ['entry', 'exit']),
        id: route.id,
      );
      final keys = {...repository.read().connections.single.secrets};
      await panel.saveNamedRoute(
        repository.revision,
        NamedRoute(
          id: route.id,
          name: 'Renamed',
          nodes: ['entry', 'exit'],
          policies: {
            'entry': const NodeRouting(
              rules: [RoutingRule('domain', 'ads.example.com', 'block')],
            ),
          },
        ),
        id: route.id,
      );
      expect(repository.read().connections.single.secrets, keys);
      expect(repository.read().grants.single.credentials, oldGrants);
      expect(await native.readAsString(), baselineConfig);
      expect(supervisor.calls, isEmpty);
    },
  );

  test(
    'named route bindings preserve credentials and reject stale revisions',
    () async {
      final created = await panel.saveNamedRoute(
        repository.revision,
        const NamedRoute(id: '', name: 'Local', nodes: ['local']),
      );
      final route = created.routes.single;
      final first = (await panel.saveConnection(
        repository.revision,
        input().copyWith(routeId: route.id),
      )).connections.single;
      await recipient(first.id);
      final oldSecrets = {...repository.read().connections.single.secrets};
      final oldGrants = {...repository.read().grants.single.credentials};
      final rev = repository.revision;
      final changed = await panel.saveNamedRoute(
        rev,
        NamedRoute(
          id: route.id,
          name: 'Filtered',
          nodes: ['local'],
          policies: {
            'local': const NodeRouting(
              rules: [RoutingRule('domain', 'ads.example.com', 'block')],
            ),
          },
        ),
        id: route.id,
      );
      expect(changed.connections.single.routeId, route.id);
      expect(
        changed.connections.single.routing['local']!.rules.single.target,
        'ads.example.com',
      );
      expect(repository.read().connections.single.secrets, oldSecrets);
      expect(repository.read().grants.single.credentials, oldGrants);
      expect(await native.readAsString(), contains('ads.example.com'));
      await expectLater(
        panel.saveNamedRoute(rev, route, id: route.id),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'state_changed'),
        ),
      );
      await expectLater(
        panel.deleteNamedRoute(repository.revision, route.id),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'route_in_use'),
        ),
      );
      repository.close();
      repository = PanelRepository(
        '${directory.path}/panel.sqlite',
        defaultAddress: 'panel.example.net',
      );
      panel = service();
      await panel.initialize();
      expect((await panel.snapshot()).routes.single.name, 'Filtered');
      expect(await panel.isSynchronized(), true);
      await panel.saveConnection(
        repository.revision,
        first.copyWith(routeId: '', route: [], routing: {}),
        id: first.id,
      );
      await panel.deleteNamedRoute(repository.revision, route.id);
      expect((await panel.snapshot()).routes, isEmpty);
      expect(repository.read().grants.single.credentials, oldGrants);
    },
  );

  test(
    'legacy policies migrate once without rewriting native config or credentials',
    () async {
      final c = (await connection()).connections.single;
      await recipient(c.id);
      await panel.saveRouting(
        repository.revision,
        c.id,
        'local',
        const NodeRouting(
          rules: [RoutingRule('domain', 'ads.example.com', 'block')],
        ),
      );
      final nativeBefore = await native.readAsString();
      final firstRead = repository.read();
      final route = firstRead.namedRoutes.single;
      expect(route.nodes, ['local']);
      expect(firstRead.connections.single.value.routeId, route.id);
      final credentials = firstRead.grants.single.credentials;
      await panel.saveSettings(
        repository.revision,
        'New name',
        firstRead.address,
      );
      expect(repository.read().namedRoutes.single.id, route.id);
      expect(repository.read().grants.single.credentials, credentials);
      expect(await native.readAsString(), nativeBefore);
      expect(await panel.isSynchronized(), true);
    },
  );

  test(
    'core settings persist transactionally and preserve grants across reopen',
    () async {
      final id = (await connection()).connections.single.id;
      await recipient(id);
      final grants = repository.read().grants.single.credentials;
      final form = await panel.coreSettings('primary');
      expect(form.revision, repository.revision);
      expect((await panel.snapshot()).settingsInstances, ['primary']);
      expect(form.values.keys, isNot(contains('_baseline')));
      final snapshot = await panel.saveCoreSettings(form.revision, 'primary', {
        ...form.values,
        'logLevel': 'debug',
        'blockPrivate': 'true',
        'dnsMode': 'custom',
        'resolvers': 'https://dns.google/dns-query',
      });
      final document = jsonDecode(await native.readAsString()) as Map;
      expect(document['log-level'], 'debug');
      expect(document['mode'], 'rule');
      expect(
        (document['listeners'] as List).single['rule'],
        startsWith('sky-ui/access/'),
      );
      expect(repository.read().grants.single.credentials, grants);
      expect(snapshot.revision, form.revision + 1);
      expect(repository.pending, isNull);
      repository.close();
      repository = PanelRepository(
        '${directory.path}/panel.sqlite',
        defaultAddress: 'panel.example.net',
      );
      panel = service();
      await panel.initialize();
      expect((await panel.coreSettings('primary')).values['logLevel'], 'debug');
      expect(repository.read().grants.single.credentials, grants);
      final next = await panel.coreSettings('primary');
      await panel.saveCoreSettings(next.revision, 'primary', {
        ...next.values,
        'blockPrivate': 'false',
        'dnsMode': 'existing',
      });
      final restored = jsonDecode(await native.readAsString()) as Map;
      expect(restored['mode'], 'direct');
      expect(restored.containsKey('dns'), false);
      expect((restored['listeners'] as List).single['proxy'], 'DIRECT');
    },
  );
  test('settings-only changes are isolated by managed instance', () async {
    final otherFile = File('${directory.path}/second.yaml');
    await otherFile.writeAsString(baseline);
    final other = CoreManager(
      core: ManagedCore(
        id: 'second',
        coreId: 'mihomo',
        service: 'second.service',
        binary: '/unused',
        directory: directory.path,
        configuration: otherFile.path,
        controller: Uri.parse('http://127.0.0.1:19092'),
        secret: 'other-private',
      ),
      adapters: {'mihomo': Adapter()},
      supervisor: Supervisor(),
      stateDirectory: '${directory.path}/second-state',
    );
    panel = service(additionalManagers: [other]);
    await panel.initialize();
    final first = await native.readAsString();
    await panel.saveCoreSettings(repository.revision, 'second', {
      'logLevel': 'debug',
    });
    expect(await native.readAsString(), first);
    expect(
      (jsonDecode(await otherFile.readAsString()) as Map)['log-level'],
      'debug',
    );
    expect(repository.read().coreSettings.keys, ['second']);
    expect(repository.instanceHash('second'), isNotNull);
    expect((await panel.coreSettings('primary')).values['logLevel'], 'info');
    expect((await panel.coreSettings('second')).values['logLevel'], 'debug');
  });
  test(
    'invalid core settings and stale writes never modify native or stored state',
    () async {
      final original = await native.readAsString();
      await expectLater(
        panel.saveCoreSettings(repository.revision, 'primary', {
          'dnsMode': 'custom',
          'resolvers': 'https://dns.example/#skip-cert-verify',
        }),
        throwsA(isA<ApiException>()),
      );
      expect(await native.readAsString(), original);
      expect(repository.read().coreSettings, isEmpty);
      expect(repository.revision, 0);
      await connection();
      await expectLater(
        panel.saveCoreSettings(0, 'primary', {'logLevel': 'error'}),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'state_changed'),
        ),
      );
      adapter.available = false;
      await expectLater(
        panel.saveCoreSettings(repository.revision, 'primary', {
          'logLevel': 'debug',
        }),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'binary_missing'),
        ),
      );
      expect(repository.read().coreSettings, isEmpty);
    },
  );
  test(
    'settings validation and failed activation roll back native and metadata',
    () async {
      supervisor.state = CoreProcessState.active;
      final original = await native.readAsString();
      adapter.invalidCandidate = true;
      await expectLater(
        panel.saveCoreSettings(0, 'primary', {'logLevel': 'debug'}),
        throwsA(isA<ApiException>()),
      );
      expect(await native.readAsString(), original);
      expect(repository.read().coreSettings, isEmpty);
      expect(supervisor.calls, isEmpty);
      adapter.invalidCandidate = false;
      supervisor.failures = 1;
      await expectLater(
        panel.saveCoreSettings(0, 'primary', {'logLevel': 'debug'}),
        throwsA(isA<ApiException>()),
      );
      expect(await native.readAsString(), original);
      expect(repository.read().coreSettings, isEmpty);
      expect(repository.revision, 0);
      expect(repository.pending, isNull);
      expect(supervisor.state, CoreProcessState.active);
      await panel.saveCoreSettings(0, 'primary', {'logLevel': 'error'});
      expect((await panel.coreSettings('primary')).values['logLevel'], 'error');
    },
  );
  test(
    'settings API rejects untyped payload and exposes no native secrets',
    () async {
      final server = await serve(
        createApplication(config, manager, panel: panel),
        InternetAddress.loopbackIPv4,
        0,
      );
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      Future<({int status, String body})> request(
        String method,
        String path, [
        Object? payload,
      ]) async {
        final req = await client.openUrl(
          method,
          Uri.parse('http://127.0.0.1:${server.port}$path'),
        );
        if (payload != null) {
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(payload));
        }
        final res = await req.close();
        return (
          status: res.statusCode,
          body: await utf8.decoder.bind(res).join(),
        );
      }

      try {
        const path = '/api/v1/cores/primary/settings';
        final form = await request('GET', path);
        expect(form.status, 200);
        expect(form.body, isNot(contains('controller-only-secret')));
        expect(
          (await request('PUT', path, {
            'revision': 0,
            'values': {'blockPrivate': true},
          })).status,
          400,
        );
        expect(
          (await request('PUT', path, {
            'revision': 0,
            'values': {'_baseline': '{}'},
          })).status,
          422,
        );
        expect(
          (await request('GET', '/api/v1/cores/unknown/settings')).status,
          404,
        );
        expect(
          (await request('PUT', path, {
            'revision': 0,
            'values': {'logLevel': 'debug'},
          })).status,
          200,
        );
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    },
  );
  test(
    'missing core keeps connections and grants but blocks execution and sharing',
    () async {
      final connectionId = (await connection()).connections.single.id;
      final person = (await recipient(connectionId)).recipients.single;
      final before = repository.read();
      adapter.available = false;
      adapter.ready = false;
      supervisor.state = CoreProcessState.inactive;
      final missing = await panel.snapshot();
      expect(missing.coreAvailability, {'mihomo': false});
      expect(PanelSnapshot.fromJson(missing.toJson()).coreAvailability, {
        'mihomo': false,
      });
      expect(missing.connections.single.enabled, true);
      expect(missing.connections.single.id, connectionId);
      expect(missing.deliveryReady, false);
      expect(missing.errorCode, 'binary_missing');
      await expectLater(
        panel.executeCore(CoreOperation.start),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'binary_missing'),
        ),
      );
      await expectLater(
        panel.share(person.id),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'binary_missing'),
        ),
      );
      expect(
        repository.read().grants.single.credentials,
        before.grants.single.credentials,
      );
      adapter.available = true;
      adapter.ready = true;
      supervisor.state = CoreProcessState.active;
      expect((await panel.snapshot()).deliveryReady, true);
      expect(
        repository.read().grants.single.credentials,
        before.grants.single.credentials,
      );
    },
  );
  test(
    'draft generators preserve stored records and skip registered ports',
    () async {
      final c = (await connection()).connections.single;
      final before = repository.read().connections.single;
      final revision = repository.revision;
      final generated = await panel.generateConnectionFields(
        revision,
        'mihomo',
        'vless',
        'port',
        {'port': '${c.port}'},
      );
      expect(int.parse(generated['port']!), isNot(c.port));
      expect(int.parse(generated['port']!), inInclusiveRange(20000, 59999));
      expect(repository.revision, revision);
      expect(repository.read().connections.single.secrets, before.secrets);
      await expectLater(
        panel.generateConnectionFields(
          revision,
          'mihomo',
          'vless',
          'tlsPrivateKey',
          {},
        ),
        throwsA(isA<ApiException>()),
      );
    },
  );
  tearDown(() async {
    repository.close();
    await directory.delete(recursive: true);
  });
  test(
    'isolated access preserves each recipient port/key when another recipient is revoked',
    () async {
      final created = await panel.saveConnection(
        repository.revision,
        input(protocol: 'shadowsocks'),
      );
      final c = created.connections.single;
      await recipient(c.id, name: 'First');
      await recipient(c.id, name: 'Second');
      final before = repository.read(),
          first = before.recipients.first,
          second = before.recipients.last;
      final firstGrant = before.grants.first, secondGrant = before.grants.last;
      // The OS may reserve the preferred TCP port for UDP before allocation.
      expect(
        int.parse(firstGrant.credentials['port']!),
        inInclusiveRange(1024, 65535),
      );
      expect(
        firstGrant.credentials['port'],
        isNot(secondGrant.credentials['port']),
      );
      expect(
        firstGrant.credentials['password'],
        isNot(secondGrant.credentials['password']),
      );
      final public = jsonEncode((await panel.snapshot()).toJson());
      expect(public, isNot(contains(firstGrant.credentials['password']!)));
      expect(
        (jsonDecode(await native.readAsString()) as Map)['listeners'],
        hasLength(2),
      );
      await expectLater(
        panel.saveConnection(
          repository.revision,
          Connection(
            id: c.id,
            name: c.name,
            coreId: c.coreId,
            protocolId: c.protocolId,
            port: int.parse(secondGrant.credentials['port']!),
            settings: c.settings,
          ),
          id: c.id,
        ),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'port_in_use'),
        ),
      );
      await panel.saveRecipient(
        repository.revision,
        before.publicRecipient(first).copyWith(enabled: false),
        id: first.id,
      );
      final listeners =
          (jsonDecode(await native.readAsString()) as Map)['listeners'] as List;
      expect(listeners, hasLength(1));
      expect(
        listeners.single['port'],
        int.parse(secondGrant.credentials['port']!),
      );
      expect(listeners.single['password'], secondGrant.credentials['password']);
      final after = repository.read();
      expect(after.grants.first.credentials, firstGrant.credentials);
      expect(after.grants.last.credentials, secondGrant.credentials);
      final link = (await panel.share(second.id)).links.single;
      expect(
        Uri.parse(link.uri).port,
        int.parse(secondGrant.credentials['port']!),
      );
    },
  );

  test(
    'core-directory staging links cannot overwrite private API files',
    () async {
      final target = File('${directory.path}/private-record.txt');
      await target.writeAsString('untouched');
      await Link('${native.path}.validate').create(target.path);
      await Link('${native.path}.next').create(target.path);
      await connection();
      expect(await target.readAsString(), 'untouched');
      expect(await Link('${native.path}.next').exists(), true);
      expect(await Directory('${directory.path}/staging').list().isEmpty, true);
    },
    skip: !Platform.isLinux,
  );
  test(
    'no demo seed; records survive reopening; public DTO excludes credentials',
    () async {
      expect((await panel.snapshot()).connections, isEmpty);
      final c = (await connection()).connections.single;
      expect(c.instanceId, 'primary');
      expect(jsonDecode(await native.readAsString())['listeners'], isEmpty);
      final users = await recipient(c.id);
      final public = jsonEncode(users.toJson());
      final private = repository.read();
      expect(
        public,
        isNot(contains(private.connections.single.secrets['privateKey']!)),
      );
      expect(public, isNot(contains(private.recipients.single.token)));
      expect(
        public,
        isNot(contains(private.grants.single.credentials['uuid']!)),
      );
      repository.close();
      repository = PanelRepository(
        '${directory.path}/panel.sqlite',
        defaultAddress: 'ignored.net',
      );
      panel = service();
      final restored = await panel.snapshot();
      expect(restored.connections.single.id, c.id);
      expect(restored.recipients.single.connectionIds, [c.id]);
      expect(restored.revision, 2);
    },
  );
  test(
    'distinct UUIDs, client-only exports, native and subscription revocation',
    () async {
      final c = (await connection()).connections.single;
      final first = (await recipient(c.id)).recipients.single;
      final firstToken = await token(first.id);
      final second = (await recipient(c.id, name: 'Второй')).recipients.last;
      final before = repository.read();
      expect(before.grants.map((g) => g.credentials['uuid']).toSet().length, 2);
      final exported = jsonDecode(await panel.subscription(firstToken)) as Map;
      expect((exported['proxies'] as List).length, 1);
      expect(jsonEncode(exported), isNot(contains('private-key')));
      expect(jsonEncode(exported), isNot(contains(manager.core.secret)));
      expect(
        jsonEncode(exported),
        isNot(contains(before.grants.last.credentials['uuid']!)),
      );
      final share = await panel.share(first.id);
      expect(share.subscriptionUrls['v2ray'], endsWith('.txt'));
      final text = utf8
          .decode(
            base64.decode(
              await panel.subscription(firstToken, format: 'v2ray'),
            ),
          )
          .trim();
      expect(text, share.links.single.uri);
      final uri = Uri.parse((await panel.share(first.id)).links.single.uri);
      expect(uri.scheme, 'vless');
      expect(uri.userInfo, before.grants.first.credentials['uuid']);
      expect(uri.queryParameters['security'], 'reality');
      expect(Uri.decodeComponent(uri.fragment), c.name);
      await panel.saveRecipient(
        repository.revision,
        first.copyWith(enabled: false),
        id: first.id,
      );
      final listeners =
          (jsonDecode(await native.readAsString()) as Map)['listeners'] as List;
      final users = listeners.single['users'] as List;
      expect(users.length, 1);
      expect(users.single['uuid'], before.grants.last.credentials['uuid']);
      await expectLater(
        panel.subscription(firstToken),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 404)),
      );
      await expectLater(
        panel.subscription(firstToken, format: 'v2ray'),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 404)),
      );
      expect((await panel.share(second.id)).links.length, 1);
      await panel.deleteRecipient(repository.revision, first.id);
      expect(repository.recipientForToken(firstToken), isNull);
    },
  );
  test('grant removal rotates credentials; toggling preserves them', () async {
    final c = (await connection()).connections.single;
    final user = (await recipient(c.id)).recipients.single;
    final original = repository.read().grants.single.credentials['uuid'];
    await panel.saveRecipient(
      repository.revision,
      user.copyWith(enabled: false),
      id: user.id,
    );
    await panel.saveRecipient(repository.revision, user, id: user.id);
    expect(repository.read().grants.single.credentials['uuid'], original);
    await panel.saveRecipient(
      repository.revision,
      Recipient(id: user.id, name: user.name),
      id: user.id,
    );
    await panel.saveRecipient(repository.revision, user, id: user.id);
    expect(
      repository.read().grants.single.credentials['uuid'],
      isNot(original),
    );
  });
  test(
    'invalid candidate never touches running file or committed database',
    () async {
      adapter.invalidCandidate = true;
      await expectLater(
        connection(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'configuration_invalid',
          ),
        ),
      );
      expect(repository.revision, 0);
      expect(repository.read().connections, isEmpty);
      expect(await native.readAsString(), baseline);
      expect(supervisor.calls, isEmpty);
      expect(repository.pending, isNull);
    },
  );
  test(
    'activation failure restores file and records and leaves queue usable',
    () async {
      final c = (await connection()).connections.single;
      final previous = await native.readAsString();
      final revision = repository.revision;
      supervisor.failures = 1;
      await expectLater(
        recipient(c.id),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'service_failed'),
        ),
      );
      expect(await native.readAsString(), previous);
      expect(repository.revision, revision);
      expect(repository.read().recipients, isEmpty);
      expect(repository.pending, isNull);
      expect(supervisor.state, CoreProcessState.active);
      await recipient(c.id);
      expect(repository.read().recipients.length, 1);
    },
  );
  test('missing listener rolls back even with a healthy controller', () async {
    final c = (await connection()).connections.single;
    final old = await native.readAsString();
    codec.failedProbes = 1;
    await expectLater(
      recipient(c.id),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'listener_not_ready'),
      ),
    );
    expect(await native.readAsString(), old);
    expect(repository.read().recipients, isEmpty);
  });
  test('startup recovers interrupted deployment from durable intent', () async {
    final c = (await connection()).connections.single;
    final old = await native.readAsString();
    repository.prepare(DeploymentIntent(old, '{"listeners":[]}', true));
    await native.writeAsString('{"listeners":[]}');
    repository.close();
    repository = PanelRepository(
      '${directory.path}/panel.sqlite',
      defaultAddress: 'ignored.net',
    );
    panel = service();
    await panel.initialize();
    expect(await native.readAsString(), old);
    expect(repository.pending, isNull);
    expect((await panel.snapshot()).connections.single.id, c.id);
  });
  test('failed rollback preserves recovery intent and blocks writes', () async {
    final c = (await connection()).connections.single;
    supervisor.failures = 2;
    await expectLater(
      recipient(c.id),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'configuration_rollback_failed',
        ),
      ),
    );
    expect(repository.pending, isNotNull);
    expect((await panel.snapshot()).synchronized, false);
    await expectLater(
      connection(),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'configuration_rollback_failed',
        ),
      ),
    );
    supervisor.failures = 0;
    await panel.initialize();
    expect(repository.pending, isNull);
  });
  test(
    'startup recovers an interrupted auto-start with a stopped unit',
    () async {
      final previous = await native.readAsString();
      const candidate = '{"listeners":[]}';
      final intent = jsonEncode({
        'skyUiDeployment': 2,
        'instances': {
          manager.core.id: {
            'previous': previous,
            'candidate': candidate,
            'wasRunning': false,
            'autoStart': true,
          },
        },
      });
      repository.prepare(DeploymentIntent(intent, intent, false));
      await native.writeAsString(candidate);
      supervisor.state = CoreProcessState.inactive;
      supervisor.calls.clear();

      await panel.initialize();

      expect(supervisor.calls, ['stop']);
      expect(repository.pending, isNull);
      expect(await native.readAsString(), previous);
      expect((await panel.snapshot()).synchronized, true);
    },
  );
  test(
    'native drift blocks export and auto-start; emergency stop remains usable',
    () async {
      final c = (await connection()).connections.single;
      final user = (await recipient(c.id)).recipients.single;
      await native.writeAsString(baseline);
      expect((await panel.snapshot()).deliveryReady, false);
      await expectLater(
        panel.share(user.id),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'configuration_out_of_sync',
          ),
        ),
      );
      await expectLater(
        panel.executeCore(CoreOperation.start),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'configuration_out_of_sync',
          ),
        ),
      );
      await panel.executeCore(CoreOperation.stop);
      expect(supervisor.state, CoreProcessState.inactive);
    },
  );
  test('stale concurrent writes cannot overwrite committed changes', () async {
    final results = await Future.wait([
      connection().then<Object>((s) => s, onError: (Object e) => e),
      connection().then<Object>((s) => s, onError: (Object e) => e),
    ]);
    expect(results.whereType<PanelSnapshot>().length, 1);
    expect(results.whereType<ApiException>().single.code, 'state_changed');
    expect(repository.revision, 1);
  });
  test('editing configuration never starts a stopped core', () async {
    await panel.executeCore(CoreOperation.stop);
    supervisor.calls.clear();
    final c = (await connection()).connections.single;
    final s = await recipient(c.id);
    expect(s.deliveryReady, false);
    expect(supervisor.calls, isEmpty);
    expect(manager.desired, CoreDesiredState.stopped);
  });
  test('unsupported settings and reserved ports do not persist', () async {
    await expectLater(
      panel.saveConnection(0, input(protocol: 'unknown-protocol')),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'protocol_unavailable',
        ),
      ),
    );
    await expectLater(
      panel.saveConnection(
        0,
        input(settings: {'transport': 'unknown-transport'}),
      ),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'settings_unsupported',
        ),
      ),
    );
    freePort = 443;
    await expectLater(
      connection(),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'port_reserved'),
      ),
    );
    expect(repository.revision, 0);
  });
  test(
    'default endpoint follows gateway changes; explicit endpoint survives them',
    () async {
      expect((await panel.snapshot()).address, 'panel.example.net');
      repository.close();
      repository = PanelRepository(
        '${directory.path}/panel.sqlite',
        defaultAddress: 'new.example.net',
      );
      panel = service();
      expect((await panel.snapshot()).address, 'new.example.net');
      await panel.saveSettings(
        repository.revision,
        'Сервер',
        'vpn.example.net',
      );
      repository.close();
      repository = PanelRepository(
        '${directory.path}/panel.sqlite',
        defaultAddress: 'third.example.net',
      );
      panel = service();
      expect((await panel.snapshot()).address, 'vpn.example.net');
    },
  );
  test(
    'one subscription URL negotiates formats and preserves revocation',
    () async {
      final connectionId = (await connection()).connections.single.id;
      final user = (await recipient(connectionId)).recipients.single;
      final share = await panel.share(user.id);
      final path = Uri.parse(share.subscriptionUrl).path;
      expect(path, matches(RegExp(r'^/s/[A-Za-z0-9_-]{43}$')));
      final server = await serve(
        createApplication(config, manager, panel: panel),
        InternetAddress.loopbackIPv4,
        0,
      );
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      Future<({int status, String body, String? type, String? vary})> fetch(
        String suffix,
        String agent, {
        String method = 'GET',
      }) async {
        final request = await client.openUrl(
          method,
          Uri.parse('http://127.0.0.1:${server.port}$path$suffix'),
        );
        request.headers.set('user-agent', agent);
        final response = await request.close();
        return (
          status: response.statusCode,
          body: await utf8.decoder.bind(response).join(),
          type: response.headers.value('content-type'),
          vary: response.headers.value('vary'),
        );
      }

      try {
        for (final agent in [
          'V2Box/10.1',
          'v2rayNG/1.10',
          'Happ/1.63.1',
          'Hiddify/4.1',
          'Karing/1.2',
          '',
        ]) {
          final result = await fetch('', agent);
          expect(result.status, 200);
          expect(result.type, startsWith('text/plain'));
          expect(result.vary, 'Accept, User-Agent');
          expect(
            utf8.decode(base64Decode(result.body)).trim(),
            share.links.single.uri,
          );
        }
        for (final agent in [
          'clash.meta',
          'clash-verge/2.4',
          'FlClash/0.8',
          'Stash/3.6',
        ]) {
          final result = await fetch('', agent);
          expect(result.status, 200);
          expect(result.type, startsWith('application/yaml'));
          final profile = jsonDecode(result.body) as Map;
          expect((profile['proxies'] as List).single['type'], 'vless');
          expect(
            (profile['proxies'] as List).single['uuid'],
            Uri.parse(share.links.single.uri).userInfo,
          );
        }
        expect(
          (await fetch('.yaml', 'V2Box/10.1')).type,
          startsWith('application/yaml'),
        );
        expect(
          (await fetch('.txt', 'clash.meta')).type,
          startsWith('text/plain'),
        );
        final head = await fetch('', 'clash.meta', method: 'HEAD');
        expect(head.status, 200);
        expect(head.body, isEmpty);
        await panel.saveRecipient(
          repository.revision,
          user.copyWith(enabled: false),
          id: user.id,
        );
        for (final suffix in ['', '.yaml', '.txt']) {
          expect((await fetch(suffix, 'clash.meta')).status, 404);
          expect((await fetch(suffix, 'V2Box/10.1')).status, 404);
        }
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    },
  );
  test(
    'gateway credential is required for loopback access, including subscription routing',
    () async {
      final c = (await connection()).connections.single;
      final user = (await recipient(c.id)).recipients.single;
      final path = Uri.parse((await panel.share(user.id)).subscriptionUrl).path;
      final secret = List.filled(64, 'a').join();
      final secured = ServerConfig(
        requireOwnerAuth: false,
        port: 39242,
        webOrigin: config.webOrigin,
        publicDirectory: directory.path,
        dataDirectory: directory.path,
        core: config.core,
        gatewaySecret: secret,
      );
      final server = await serve(
        createApplication(secured, manager, panel: panel),
        InternetAddress.loopbackIPv4,
        0,
      );
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      Future<int> status(
        String target, {
        String? credential,
        bool foreign = false,
      }) async {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}$target'),
        );
        if (credential != null)
          request.headers.set('x-sky-ui-gateway', credential);
        if (foreign) {
          request.headers.set('origin', 'https://foreign.example');
          request.headers.set('sec-fetch-site', 'cross-site');
        }
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      try {
        expect(await status('/api/v1/health'), 200);
        expect(await status('/api/v1/panel'), 401);
        expect(await status('/api/v1/cores/primary/settings'), 401);
        expect(await status('/api/v1/panel', credential: 'wrong'), 401);
        expect(await status('/api/v1/panel', credential: secret), 200);
        expect(
          await status('/api/v1/panel', credential: secret, foreign: true),
          403,
        );
        expect(await status(path), 401);
        expect(await status(path, credential: secret, foreign: true), 200);
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    },
  );
  test(
    'subscription reads and device enrollment retain origin and host guards',
    () async {
      final c = (await connection()).connections.single;
      final user = (await recipient(c.id)).recipients.single;
      final path = Uri.parse((await panel.share(user.id)).subscriptionUrl).path;
      final server = await serve(
        createApplication(config, manager, panel: panel),
        InternetAddress.loopbackIPv4,
        0,
      );
      final client = HttpClient()..findProxy = (_) => 'DIRECT';
      Future<int> status(
        String method,
        String target, {
        String? host,
        bool foreign = true,
        String? body,
      }) async {
        final request = await client.openUrl(
          method,
          Uri.parse('http://127.0.0.1:${server.port}$target'),
        );
        if (host != null) request.headers.set('host', host);
        if (foreign) {
          request.headers.set('origin', 'https://foreign.example');
          request.headers.set('sec-fetch-site', 'cross-site');
        }
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(body);
        }
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      try {
        for (final target in [path, '$path.yaml', '$path.txt']) {
          expect(await status('GET', target), 200);
          expect(await status('HEAD', target), 200);
          expect(await status('POST', target), 403);
          expect(await status('GET', target, host: 'evil.example'), 403);
        }
        const relinkType = 'application/vnd.sky-ui.relink-v1+json';
        final relink = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}$path'),
        );
        relink.headers.set(HttpHeaders.acceptHeader, relinkType);
        final profile = await relink.close();
        expect(profile.statusCode, 200);
        expect(profile.headers.contentType?.mimeType, relinkType);
        expect(profile.headers.value('cache-control'), 'no-store');
        final bundle =
            jsonDecode(await utf8.decoder.bind(profile).join()) as Map;
        expect(bundle['version'], 1);
        final entry = (bundle['profiles'] as List).single as Map;
        expect(entry['protocol'], c.protocolId);
        expect(entry['port'], c.port);
        expect(entry['credentials'], contains('uuid'));
        expect(entry['credentials'], isNot(contains('privateKey')));
        final install = secureToken();
        Future<Map> enroll() async {
          final request = await client.postUrl(
            Uri.parse('http://127.0.0.1:${server.port}$path'),
          );
          request.headers.set(HttpHeaders.acceptHeader, relinkType);
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode({'installation': install, 'name': 'PC'}));
          final response = await request.close();
          expect(response.statusCode, 200);
          return jsonDecode(await utf8.decoder.bind(response).join()) as Map;
        }

        final enrolled = await Future.wait([enroll(), enroll()]);
        expect(enrolled, [bundle, bundle]);
        final snapshot = await panel.snapshot();
        expect(snapshot.recipients.single.devices.single.name, 'PC');
        expect(snapshot.revision, 3);
        expect(await status('GET', '/api/v1/panel'), 403);
        expect(await status('GET', '/api/v1/cores/primary/settings'), 403);
        expect(await status('GET', path, host: 'evil.example'), 403);
        expect(await status('GET', '/s/not-a-token.yaml'), 403);
        expect(
          await status(
            'POST',
            '/api/v1/recipients',
            foreign: false,
            body: '{}',
          ),
          400,
        );
        final logs = await client.getUrl(
          Uri.parse('http://127.0.0.1:${server.port}/api/v1/cores/sky-ui/logs'),
        );
        final logResponse = await logs.close();
        expect(logResponse.statusCode, 200);
        final logText = await utf8.decoder.bind(logResponse).join();
        expect(logText, contains('POST recipient HTTP 400 request_invalid'));
        expect(logText, contains('Subscription device registered'));
        expect(logText, isNot(contains(install)));
        expect(logText, isNot(contains(path)));
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    },
  );

  test('AWG devices on the same grant get independent stable peers', () async {
    // A TCP-assigned ephemeral port can be reserved for UDP on Windows.
    final udp = await RawDatagramSocket.bind(
      '0.0.0.0',
      0,
      reuseAddress: false,
      reusePort: false,
    );
    freePort = udp.port;
    udp.close();
    final awgFile = File('${directory.path}/awg.json')..writeAsStringSync('{}');
    final awg = CoreManager(
      core: ManagedCore(
        id: 'amneziawg',
        coreId: 'amneziawg',
        service: 'sky-ui-amneziawg.service',
        binary: '/unused',
        directory: directory.path,
        configuration: awgFile.path,
        controller: Uri.parse('http://127.0.0.1:19093'),
        secret: '',
      ),
      adapters: {'amneziawg': Adapter()},
      supervisor: Supervisor()..state = CoreProcessState.active,
      stateDirectory: '${directory.path}/awg-state',
    );
    panel = service(additionalManagers: [awg]);
    final state = await panel.saveConnection(
      repository.revision,
      Connection(
        id: '',
        name: 'AWG',
        coreId: 'amneziawg',
        instanceId: 'amneziawg',
        protocolId: 'amneziawg',
        port: freePort,
      ),
    );
    final user = (await recipient(
      state.connections.single.id,
    )).recipients.single;
    final parentToken = await token(user.id);
    expect(await panel.subscription(parentToken), contains('wireguard'));
    final firstInstall = secureToken();
    final tokens = await Future.wait([
      panel.enrollSubscription(parentToken, firstInstall, 'Desktop'),
      panel.enrollSubscription(parentToken, secureToken(), 'Phone'),
    ]);
    final first = await panel.subscription(tokens[0], format: 'relink');
    final second = await panel.subscription(tokens[1], format: 'relink');
    expect(first, isNot(second));
    final grants = repository.read().grants;
    expect(grants, hasLength(3));
    expect(grants.map((g) => g.credentials['address']).toSet(), hasLength(3));
    expect(grants.map((g) => g.credentials['publicKey']).toSet(), hasLength(3));
    final revision = repository.revision;
    repository.close();
    repository = PanelRepository(
      '${directory.path}/panel.sqlite',
      defaultAddress: 'panel.example.net',
    );
    panel = service(additionalManagers: [awg]);
    expect(
      await panel.enrollSubscription(parentToken, firstInstall, 'PC'),
      tokens[0],
    );
    expect(repository.revision, revision);
    expect(await panel.subscription(tokens[0], format: 'relink'), first);
    final enrolled = (await panel.snapshot()).recipients.single;
    expect(
      enrolled.devices.map((d) => d.name),
      unorderedEquals(['Desktop', 'Phone']),
    );
    await panel.saveRecipient(
      revision,
      enrolled.copyWith(enabled: false),
      id: user.id,
    );
    expect(
      repository.read().activeGrants(state.connections.single.id),
      isEmpty,
    );
    for (final token in tokens) {
      await expectLater(
        panel.subscription(token, format: 'relink'),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 404)),
      );
    }
  });

  test(
    'schema 1 upgrade preserves recipient tokens and native grants',
    () async {
      final connectionId = (await connection()).connections.single.id;
      final user = (await recipient(connectionId)).recipients.single;
      final previousToken = await token(user.id);
      final previousGrant = repository.read().grants.single.credentials;
      final path = '${directory.path}/panel.sqlite';
      repository.close();
      final old = sqlite3.open(path);
      try {
        old.execute('DROP TABLE recipient_devices');
        old.execute('PRAGMA user_version = 1');
      } finally {
        old.close();
      }
      repository = PanelRepository(path, defaultAddress: 'panel.example.net');
      panel = service();
      expect(await token(user.id), previousToken);
      expect(repository.read().grants.single.credentials, previousGrant);
      expect((await panel.snapshot()).recipients.single.devices, isEmpty);
      await panel.enrollSubscription(previousToken, secureToken(), 'PC');
      expect(
        (await panel.snapshot()).recipients.single.devices.single.name,
        'PC',
      );
    },
  );
}
