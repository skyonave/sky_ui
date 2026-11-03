import 'dart:convert';
import 'dart:io';
import 'package:bcrypt/bcrypt.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/features/auth/owner_auth.dart';
import 'package:sky_ui_api/src/features/maintenance/service.dart';
import 'package:sky_ui_api/src/features/updates/core_updates.dart';
import 'package:sky_ui_api/src/features/updates/panel_updates.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';
import 'core_manager_test.dart' show FakeAdapter, FakeSupervisor;

class RejectingUpdates extends CoreUpdates {
  @override
  Future<void> requireApproved(String core, String tag) async {
    throw const ApiException('core_release_unverified', status: 422);
  }
}

class RejectingPanelUpdates extends PanelUpdates {
  RejectingPanelUpdates(super.runner) : super(supported: false);
  bool refreshed = false;
  @override
  Future<PanelUpdateInfo> get({bool refresh = false}) async {
    refreshed = refresh;
    return const PanelUpdateInfo(
      currentVersion: '0.6.0-dev.4',
      available: false,
      supported: true,
      checkedAt: '2026-11-01T00:00:00Z',
    );
  }

  @override
  Future<void> requireApproved(String tag) async {
    throw const ApiException('panel_update_unavailable', status: 422);
  }
}

class MaintenanceRunner implements CommandRunner {
  final calls = <List<String>>[];
  int exitCode = 0;
  bool workerActive = false;
  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    calls.add([executable, ...arguments]);
    if (arguments.first == 'is-active')
      return CommandResult(workerActive ? 0 : 3, '');
    return CommandResult(exitCode, '');
  }
}

void main() {
  late Directory directory;
  late OwnerAuth auth;
  late HttpServer server;
  late HttpClient client;
  late Uri base;
  late MaintenanceService maintenance;
  late MaintenanceRunner runner;
  late RejectingPanelUpdates panelUpdates;
  late FakeAdapter adapter;
  const password = 'fixture-maintenance-owner';
  const gateway = 'fixture-private-gateway';
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sky-maintenance-');
    for (final name in ['inbox', 'backups']) {
      await Directory('${directory.path}/$name').create();
    }
    final seed = File('${directory.path}/seed')
      ..writeAsStringSync(
        'admin ${BCrypt.hashpw(password, BCrypt.gensalt(logRounds: 4))}',
      );
    auth = OwnerAuth('${directory.path}/owner.sqlite', secure: true);
    await auth.initialize(seed.path);
    runner = MaintenanceRunner();
    panelUpdates = RejectingPanelUpdates(runner);
    maintenance = MaintenanceService(
      runner,
      directory: directory.path,
      supported: true,
    );
    adapter = FakeAdapter();
    final manager = CoreManager(
      core: ManagedCore(
        id: 'primary',
        coreId: 'mihomo',
        service: 'sky-ui-mihomo.service',
        binary: '/unused',
        directory: '/unused',
        configuration: '/unused',
        controller: Uri.parse('http://127.0.0.1:19090'),
        secret: 'fixture',
      ),
      adapters: {'mihomo': adapter},
      supervisor: FakeSupervisor(),
      stateDirectory: directory.path,
    );
    server = await serve(
      createApplication(
        ServerConfig(
          port: 0,
          webOrigin: Uri.parse('https://owner.example'),
          publicDirectory: directory.path,
          dataDirectory: directory.path,
          core: ManagedCore(
            id: 'primary',
            coreId: 'mihomo',
            service: 'sky-ui-mihomo.service',
            binary: '/unused',
            directory: '/unused',
            configuration: '/unused',
            controller: Uri.parse('http://127.0.0.1:19090'),
            secret: 'fixture',
          ),
          gatewaySecret: gateway,
        ),
        manager,
        auth: auth,
        maintenance: maintenance,
        coreUpdates: RejectingUpdates(),
        panelUpdates: panelUpdates,
      ),
      InternetAddress.loopbackIPv4,
      0,
    );
    base = Uri.parse('http://127.0.0.1:${server.port}');
    client = HttpClient()..findProxy = (_) => 'DIRECT';
  });
  tearDown(() async {
    await server.close(force: true);
    client.close(force: true);
    auth.close();
    await directory.delete(recursive: true);
  });
  Future<({int status, Map<String, dynamic> json, String? cookie})> call(
    String path, {
    String method = 'GET',
    Map<String, Object?>? payload,
    String? cookie,
    String? csrf,
    String origin = 'https://owner.example',
    bool includeGateway = true,
  }) async {
    final request = await client.openUrl(method, base.resolve(path));
    if (includeGateway) request.headers.set('x-sky-ui-gateway', gateway);
    request.headers.set('origin', origin);
    if (cookie != null) request.headers.set('cookie', cookie);
    if (csrf != null) request.headers.set('x-sky-ui-csrf', csrf);
    if (payload != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload));
    }
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return (
      status: response.statusCode,
      json: jsonDecode(body) as Map<String, dynamic>,
      cookie: response.headers.value('set-cookie')?.split(';').first,
    );
  }

  Future<({String cookie, String csrf})> login() async {
    final response = await call(
      '/api/v1/auth/login',
      method: 'POST',
      payload: {'username': 'admin', 'password': password},
    );
    return (
      cookie: response.cookie!,
      csrf: (response.json['data'] as Map)['csrf'] as String,
    );
  }

  test(
    'storage cleanup gates writes while retaining the last job and reads',
    () async {
      final who = await login();
      final result = File('${directory.path}/result.json');
      const original =
          '{"id":"fixture","action":"backup","status":"completed"}';
      result.writeAsStringSync(original);
      final marker = File('${directory.path}/cleanup-intent.json')
        ..writeAsStringSync('{}');
      expect(maintenance.busy, isTrue);
      expect(
        (await call('/api/v1/auth/session', cookie: who.cookie)).status,
        200,
      );
      final response = await call(
        '/api/v1/maintenance',
        method: 'POST',
        cookie: who.cookie,
        csrf: who.csrf,
        payload: {'action': 'backup'},
      );
      expect(response.status, 409);
      expect((response.json['error'] as Map)['code'], 'maintenance_busy');
      expect(result.readAsStringSync(), original);
      marker.deleteSync();
      expect(maintenance.busy, isFalse);
    },
  );

  test(
    'manual release checks require owner access and bypass discovery cache',
    () async {
      expect((await call('/api/v1/panel-update?refresh=true')).status, 401);
      final who = await login();
      expect(
        (await call('/api/v1/panel-update', cookie: who.cookie)).status,
        200,
      );
      expect(panelUpdates.refreshed, false);
      expect(
        (await call(
          '/api/v1/panel-update?refresh=true',
          cookie: who.cookie,
        )).status,
        200,
      );
      expect(panelUpdates.refreshed, true);
    },
  );

  test(
    'core removal requires owner confirmation and CSRF before queuing a fixed core operation',
    () async {
      final who = await login();
      for (final action in ['remove', 'install']) {
        expect(
          (await call(
            '/api/v1/maintenance',
            method: 'POST',
            payload: {'action': action, 'confirmed': true},
          )).status,
          401,
        );
        expect(
          (await call(
            '/api/v1/maintenance',
            method: 'POST',
            cookie: who.cookie,
            payload: {'action': action, 'confirmed': true},
          )).status,
          403,
        );
      }
      expect(
        (await call(
          '/api/v1/maintenance',
          method: 'POST',
          cookie: who.cookie,
          csrf: who.csrf,
          payload: {'action': 'remove'},
        )).status,
        400,
      );
      expect(runner.calls, isEmpty);
      expect(
        (await call(
          '/api/v1/maintenance',
          method: 'POST',
          cookie: who.cookie,
          csrf: who.csrf,
          payload: {'action': 'remove', 'confirmed': true},
        )).status,
        202,
      );
      final request =
          jsonDecode(
                await File(
                  '${directory.path}/inbox/request.json',
                ).readAsString(),
              )
              as Map;
      expect(request['action'], 'remove');
      expect(request['core'], 'mihomo');
      expect(request.keys, unorderedEquals(['id', 'action', 'core']));
    },
  );
  test(
    'install requires an approved release even when the binary is missing',
    () async {
      adapter.available = false;
      final who = await login();
      expect(
        (await call(
          '/api/v1/maintenance',
          method: 'POST',
          cookie: who.cookie,
          csrf: who.csrf,
          payload: {'action': 'install', 'tag': 'v99.0.0', 'confirmed': true},
        )).status,
        422,
      );
      expect(runner.calls, isEmpty);
    },
  );
  test(
    'panel update requires confirmation, CSRF and a release recheck',
    () async {
      final who = await login();
      final payload = {
        'action': 'panel-update',
        'tag': 'v0.6.0-dev.5',
        'confirmed': true,
      };
      expect(
        (await call(
          '/api/v1/maintenance',
          method: 'POST',
          payload: payload,
        )).status,
        401,
      );
      expect(
        (await call(
          '/api/v1/maintenance',
          method: 'POST',
          cookie: who.cookie,
          payload: payload,
        )).status,
        403,
      );
      expect(
        (await call(
          '/api/v1/maintenance',
          method: 'POST',
          cookie: who.cookie,
          csrf: who.csrf,
          payload: payload,
        )).status,
        422,
      );
      expect(runner.calls, isEmpty);
      expect((await call('/api/v1/panel-update')).status, 401);
    },
  );
  test('panel update queues only its fixed worker and version', () async {
    await maintenance.submit('panel-update', tag: 'v0.6.0-dev.5');
    expect(runner.calls.last, [
      'systemctl',
      'start',
      '--no-block',
      'sky-ui-update.service',
    ]);
    final request =
        jsonDecode(
              await File('${directory.path}/inbox/request.json').readAsString(),
            )
            as Map;
    expect(request.keys, unorderedEquals(['id', 'action', 'tag']));
    expect(request['tag'], 'v0.6.0-dev.5');
  });
  test(
    'unverified updates cannot reach the privileged worker even with owner confirmation',
    () async {
      final who = await login();
      final response = await call(
        '/api/v1/maintenance',
        method: 'POST',
        cookie: who.cookie,
        csrf: who.csrf,
        payload: {'action': 'update', 'tag': 'v99.0.0', 'confirmed': true},
      );
      expect(response.status, 422);
      expect(response.json['error']['code'], 'core_release_unverified');
      expect(runner.calls, isEmpty);
      expect(File('${directory.path}/inbox/request.json').existsSync(), false);
    },
  );
  test(
    'maintenance and secret archives require gateway and owner session',
    () async {
      for (final path in [
        '/api/v1/maintenance',
        '/api/v1/backups/${'a' * 32}/download',
      ]) {
        expect((await call(path)).status, 401);
        expect((await call(path, includeGateway: false)).status, 401);
      }
      expect(runner.calls, isEmpty);
    },
  );
  test(
    'confirmation, CSRF and trusted origin required before privileged submission',
    () async {
      final who = await login();
      expect(
        (await call(
          '/api/v1/maintenance',
          method: 'POST',
          cookie: who.cookie,
          payload: {'action': 'backup', 'confirmed': true},
        )).status,
        403,
      );
      expect(
        (await call(
          '/api/v1/maintenance',
          method: 'POST',
          cookie: who.cookie,
          csrf: who.csrf,
          payload: {'action': 'backup'},
        )).status,
        400,
      );
      expect(
        (await call(
          '/api/v1/maintenance',
          method: 'POST',
          cookie: who.cookie,
          csrf: who.csrf,
          origin: 'https://foreign.example',
          payload: {'action': 'backup', 'confirmed': true},
        )).status,
        403,
      );
      expect(runner.calls, isEmpty);
    },
  );
  test(
    'a queued maintenance job blocks other core mutations and duplicate jobs',
    () async {
      final who = await login();
      final response = await call(
        '/api/v1/maintenance',
        method: 'POST',
        cookie: who.cookie,
        csrf: who.csrf,
        payload: {'action': 'backup', 'confirmed': true},
      );
      expect(response.status, 202);
      expect(runner.calls.last, [
        'systemctl',
        'start',
        '--no-block',
        'sky-ui-maintenance.service',
      ]);
      expect(maintenance.busy, true);
      expect(
        (await call(
          '/api/v1/maintenance',
          cookie: who.cookie,
        )).json['data']['job']['status'],
        'queued',
      );
      expect(
        (await call(
          '/api/v1/cores/primary/actions/start',
          method: 'POST',
          cookie: who.cookie,
          csrf: who.csrf,
          payload: {},
        )).status,
        409,
      );
      expect(
        (await call(
          '/api/v1/maintenance',
          method: 'POST',
          cookie: who.cookie,
          csrf: who.csrf,
          payload: {'action': 'backup', 'confirmed': true},
        )).status,
        409,
      );
    },
  );
  test('failed worker submission clears pending request', () async {
    runner.exitCode = 1;
    await expectLater(
      maintenance.submit('backup'),
      throwsA(isA<ApiException>()),
    );
    expect(maintenance.busy, false);
    expect(await File('${directory.path}/inbox/request.json').exists(), false);
  });
  test(
    'concurrent engine submissions cannot overwrite the same job inbox',
    () async {
      final first = maintenance.submit(
        'install',
        core: 'sing-box',
        tag: 'v1.14.4',
      );
      await expectLater(
        maintenance.submit('install', core: 'xray', tag: 'v26.10.31'),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'maintenance_busy'),
        ),
      );
      final job = await first;
      final request =
          jsonDecode(
                await File(
                  '${directory.path}/inbox/request.json',
                ).readAsString(),
              )
              as Map;
      expect(request['id'], job.id);
      expect(request['core'], 'sing-box');
    },
  );
  test('unfinished additional-engine activation blocks writes', () async {
    await File('${directory.path}/engine-intent.json').writeAsString('{}');
    expect(maintenance.busy, true);
  });
  test('a finishing worker cannot accept and lose a second request', () async {
    runner.workerActive = true;
    await expectLater(
      maintenance.submit('backup'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'maintenance_busy'),
      ),
    );
    expect(await File('${directory.path}/inbox/request.json').exists(), false);
    expect(runner.calls.length, 1);
  });
  test(
    'restore paths and unregistered update cores cannot reach the worker',
    () async {
      await expectLater(
        maintenance.submit('restore', backupId: '../../etc'),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        maintenance.submit('update', core: 'unregistered', tag: 'v1.0.0'),
        throwsA(isA<ApiException>()),
      );
      expect(runner.calls, isEmpty);
    },
  );
}
