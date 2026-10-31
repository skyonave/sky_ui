import 'dart:convert';
import 'dart:io';
import 'package:dart_frog/dart_frog.dart';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:test/test.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'core_manager_test.dart' show FakeAdapter, FakeSupervisor, fixtureCore;

void main() {
  late HttpServer server;
  late HttpClient client;
  late Directory directory;
  late FakeSupervisor supervisor;
  late FakeAdapter adapter;
  late CoreManager manager;
  late Uri base;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sky-ui-http-');
    client = HttpClient()..findProxy = (_) => 'DIRECT';
    adapter = FakeAdapter();
    supervisor = FakeSupervisor();
    manager = CoreManager(
      core: fixtureCore(),
      adapters: {adapter.id: adapter},
      supervisor: supervisor,
      stateDirectory: directory.path,
    );
    final config = ServerConfig(
      port: 0,
      webOrigin: Uri.parse('http://127.0.0.1:39241'),
      publicDirectory: directory.path,
      dataDirectory: directory.path,
      core: fixtureCore(),
    );
    server = await serve(
      createApplication(config, manager),
      InternetAddress.loopbackIPv4,
      0,
      poweredByHeader: null,
    );
    base = Uri.parse('http://127.0.0.1:${server.port}');
  });
  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    await directory.delete(recursive: true);
  });
  Future<({int status, Map<String, dynamic> body})> call(
    String path, {
    String method = 'GET',
    String? origin,
    String? type,
    Map<String, String> headers = const {},
    Map<String, Object?>? payload,
  }) async {
    final request = await client.openUrl(method, base.resolve(path));
    if (origin != null) request.headers.set('origin', origin);
    if (type != null) request.headers.set('content-type', type);
    headers.forEach(request.headers.set);
    if (payload != null) request.write(jsonEncode(payload));
    final response = await request.close();
    return (
      status: response.statusCode,
      body:
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>,
    );
  }

  test(
    'clearing both native and panel buffers requires confirmation and a trusted origin',
    () async {
      manager.event('test_event');
      adapter.bufferedLogs.add(
        CoreLogEntry(
          time: DateTime.now(),
          level: 'warning',
          message: 'native event',
          source: 'core',
        ),
      );
      expect(manager.logs(), hasLength(2));
      final missing = await call(
        '/api/v1/cores/primary/logs',
        method: 'DELETE',
        type: 'application/json',
        payload: {},
      );
      expect(missing.status, 400);
      expect(manager.logs(), hasLength(2));
      final foreign = await call(
        '/api/v1/cores/primary/logs',
        method: 'DELETE',
        type: 'application/json',
        origin: 'https://untrusted.invalid',
        payload: {'confirmed': true},
      );
      expect(foreign.status, 403);
      expect(manager.logs(), hasLength(2));
      final cleared = await call(
        '/api/v1/cores/primary/logs',
        method: 'DELETE',
        type: 'application/json',
        origin: 'http://127.0.0.1:39241',
        payload: {'confirmed': true},
      );
      expect(cleared.status, 200);
      expect(manager.logs(), isEmpty);
      expect(adapter.logs, isEmpty);
      manager.event('after_clear', level: 'error');
      expect(manager.logs().single.level, 'error');
    },
  );
  test(
    'SSE delivers initial records and subsequent events without buffering',
    () async {
      manager.event('initial');
      final request = await client.getUrl(
        base.resolve('/api/v1/cores/primary/logs/events'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      expect(response.headers.contentType?.mimeType, 'text/event-stream');
      final frames = response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((s) => s.startsWith('data: '))
          .take(2)
          .toList();
      Future<void>.delayed(
        const Duration(milliseconds: 50),
        () => manager.event('live', level: 'error'),
      );
      final received = await frames.timeout(const Duration(seconds: 3));
      expect(received.first, contains('initial'));
      expect(received.last, contains('live'));
    },
  );
  test(
    'health and status are real JSON and never disclose controller secrets or paths',
    () async {
      expect((await call('/api/v1/health')).status, 200);
      final response = await call('/api/v1/cores/primary');
      expect(response.status, 200);
      expect(response.body['data']['coreId'], 'test-core');
      final text = jsonEncode(response.body);
      expect(text, isNot(contains('not-a-real-secret')));
      expect(text, isNot(contains('/unused')));
    },
  );
  test('cross-origin requests cannot trigger an operation', () async {
    final response = await call(
      '/api/v1/cores/primary/actions/start',
      method: 'POST',
      origin: 'https://untrusted.invalid',
      type: 'application/json',
    );
    expect(response.status, 403);
    expect(supervisor.calls, isEmpty);
  });
  test(
    'simple browser POST without JSON cannot trigger an operation',
    () async {
      final response = await call(
        '/api/v1/cores/primary/actions/start',
        method: 'POST',
        type: 'text/plain',
      );
      expect(response.status, 415);
      expect(supervisor.calls, isEmpty);
    },
  );
  test(
    'unknown instance and action are rejected without side effects',
    () async {
      expect(
        (await call(
          '/api/v1/cores/other/actions/start',
          method: 'POST',
          type: 'application/json',
        )).status,
        404,
      );
      expect(
        (await call(
          '/api/v1/cores/primary/actions/reboot',
          method: 'POST',
          type: 'application/json',
        )).status,
        422,
      );
      expect(supervisor.calls, isEmpty);
    },
  );
  test(
    'same-origin lifecycle request passes through the real HTTP handler',
    () async {
      final response = await call(
        '/api/v1/cores/primary/actions/start',
        method: 'POST',
        origin: 'http://127.0.0.1:39241',
        type: 'application/json',
      );
      expect(response.status, 200);
      expect(response.body['data']['controllerReady'], true);
      expect(supervisor.calls, ['start']);
    },
  );
  test(
    'forwarded public authority works only with an actual loopback Host',
    () async {
      final proxied = await call(
        '/api/v1/health',
        headers: {
          'X-Forwarded-Host': 'panel.example.com',
          'X-Forwarded-Proto': 'https',
        },
      );
      expect(proxied.status, 200);
      final rebound = await call(
        '/api/v1/health',
        headers: {
          'Host': 'attacker.example.com',
          'X-Forwarded-Host': '127.0.0.1',
        },
      );
      expect(rebound.status, 403);
    },
  );
  test('raw configuration and traversal paths are not served', () async {
    expect((await call('/.env')).status, 404);
    expect((await call('/api/v1/cores/primary/config')).status, 404);
  });
}
