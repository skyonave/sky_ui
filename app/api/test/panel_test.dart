import 'dart:convert';
import 'dart:io';
import 'package:dart_frog/dart_frog.dart';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';
import 'core_manager_test.dart' show FakeAdapter, FakeSupervisor;

class Adapter extends FakeAdapter {
  @override
  String get id => 'mihomo';
  bool invalidCandidate = false;
  @override
  Future<void> validate(ManagedCore core) async {
    if (invalidCandidate && core.configuration.endsWith('.validate'))
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
  PanelService service() => PanelService(
    config: config,
    manager: manager,
    repository: repository,
    codecs: {'mihomo': codec},
    exporter: ClashExporter(),
    additionalExporters: [V2RayExporter()],
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
      expect(firstGrant.credentials['port'], '$freePort');
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
    'public subscription is GET-only; owner API retains origin and host guards',
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
        for (final target in [path, path.replaceFirst('.yaml', '.txt')]) {
          expect(await status('GET', target), 200);
          expect(await status('HEAD', target), 200);
          expect(await status('POST', target), 403);
          expect(await status('GET', target, host: 'evil.example'), 403);
        }
        expect(await status('GET', '/api/v1/panel'), 403);
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
      } finally {
        client.close(force: true);
        await server.close(force: true);
      }
    },
  );
}
