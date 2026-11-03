import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:bcrypt/bcrypt.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/features/auth/owner_auth.dart';
import 'package:test/test.dart';
import 'support/diagnostics_fixture.dart';

void main() {
  late DiagnosticsFixture fixture;
  late OwnerAuth auth;
  late HttpServer server;
  late HttpClient client;
  late Uri base;
  const origin = 'https://owner.example',
      gateway = 'fixture-gateway',
      password = 'fixture-password';
  setUp(() async {
    fixture = DiagnosticsFixture();
    final seed = File('${fixture.work.path}/owner-seed')
      ..writeAsStringSync(
        'admin ${BCrypt.hashpw(password, BCrypt.gensalt(logRounds: 4))}',
      );
    auth = OwnerAuth('${fixture.work.path}/owner.sqlite', secure: true);
    await auth.initialize(seed.path);
    final config = ServerConfig(
      port: 0,
      webOrigin: Uri.parse(origin),
      publicDirectory: fixture.work.path,
      dataDirectory: fixture.work.path,
      core: fixture.manager.core,
      gatewaySecret: gateway,
    );
    final panel = PanelService(
      config: config,
      manager: fixture.manager,
      repository: fixture.repository,
      configurationStore: ConfigurationFiles(fixture.work.path),
      codecs: fixture.registry.codecs,
      exporter: ClashExporter(),
    );
    server = await serve(
      createApplication(
        config,
        fixture.manager,
        panel: panel,
        auth: auth,
        diagnostics: fixture.service,
      ),
      InternetAddress.loopbackIPv4,
      0,
      poweredByHeader: null,
    );
    base = Uri.parse('http://127.0.0.1:${server.port}');
    client = HttpClient()..findProxy = (_) => 'DIRECT';
  });
  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    auth.close();
    await fixture.close();
  });

  Future<({int status, Map<String, dynamic> value, String? cookie})> call(
    String path, {
    String method = 'GET',
    Map<String, Object?>? body,
    String? cookie,
    String? csrf,
    String? requestOrigin,
    bool includeGateway = true,
  }) async {
    final request = await client.openUrl(method, base.resolve(path));
    request.headers.set('Origin', requestOrigin ?? origin);
    if (includeGateway) request.headers.set('X-Sky-UI-Gateway', gateway);
    if (cookie != null) request.headers.set('Cookie', cookie);
    if (csrf != null) request.headers.set('X-Sky-UI-CSRF', csrf);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    return (
      status: response.statusCode,
      value:
          jsonDecode(await utf8.decoder.bind(response).join())
              as Map<String, dynamic>,
      cookie: response.headers.value('set-cookie')?.split(';').first,
    );
  }

  Future<({String cookie, String csrf})> login() async {
    final result = await call(
      '/api/v1/auth/login',
      method: 'POST',
      body: {'username': 'admin', 'password': password},
    );
    expect(result.status, 200);
    return (
      cookie: result.cookie!,
      csrf: (result.value['data'] as Map)['csrf'] as String,
    );
  }

  const path = '/api/v1/connections/c_fixture/diagnostics';
  test('all report endpoints require owner authentication', () async {
    expect(
      (await call(
        path,
        method: 'POST',
        body: {'revision': fixture.repository.revision},
      )).status,
      401,
    );
    expect((await call('$path/unknown')).status, 401);
    expect((await call('$path/unknown', method: 'DELETE')).status, 401);
    expect(fixture.probe.calls, isEmpty);
  });
  test(
    'gateway, origin and CSRF gates still protect diagnostic jobs',
    () async {
      final owner = await login();
      expect(
        (await call(
          path,
          method: 'POST',
          cookie: owner.cookie,
          body: {'revision': 1},
        )).status,
        403,
      );
      expect(
        (await call(
          path,
          method: 'POST',
          cookie: owner.cookie,
          csrf: owner.csrf,
          requestOrigin: 'https://untrusted.example',
          body: {'revision': 1},
        )).status,
        403,
      );
      expect(
        (await call(
          path,
          method: 'POST',
          cookie: owner.cookie,
          csrf: owner.csrf,
          includeGateway: false,
          body: {'revision': 1},
        )).status,
        401,
      );
      expect(fixture.probe.calls, isEmpty);
    },
  );
  test('request cannot supply a probe URL or arbitrary target', () async {
    final owner = await login();
    final result = await call(
      path,
      method: 'POST',
      cookie: owner.cookie,
      csrf: owner.csrf,
      body: {
        'revision': fixture.repository.revision,
        'target': 'http://127.0.0.1:19090',
      },
    );
    expect(result.status, 400);
    expect(fixture.probe.calls, isEmpty);
  });
  test(
    'authenticated run exposes stages and exact job identity without credentials',
    () async {
      final owner = await login();
      final result = await call(
        path,
        method: 'POST',
        cookie: owner.cookie,
        csrf: owner.csrf,
        body: {'revision': fixture.repository.revision},
      );
      expect(result.status, 202);
      final id = (result.value['data'] as Map)['id'] as String;
      await fixture.finish(id);
      final report = await call('$path/$id', cookie: owner.cookie);
      expect(report.status, 200);
      expect((report.value['data'] as Map)['status'], 'completed');
      expect(
        jsonEncode(report.value),
        isNot(contains('server-private-fixture')),
      );
      expect(
        jsonEncode(report.value),
        isNot(contains('recipient-token-fixture')),
      );
      expect(
        (await call(
          '/api/v1/connections/other/diagnostics/$id',
          cookie: owner.cookie,
        )).status,
        404,
      );
    },
  );
  test('cancellation also requires CSRF and stops the running probe', () async {
    fixture.probe.holdTls = Completer<void>();
    final owner = await login();
    final result = await call(
      path,
      method: 'POST',
      cookie: owner.cookie,
      csrf: owner.csrf,
      body: {'revision': fixture.repository.revision},
    );
    final id = (result.value['data'] as Map)['id'] as String;
    await fixture.probe.enteredTls.future;
    expect(
      (await call('$path/$id', method: 'DELETE', cookie: owner.cookie)).status,
      403,
    );
    final cancelled = await call(
      '$path/$id',
      method: 'DELETE',
      cookie: owner.cookie,
      csrf: owner.csrf,
    );
    expect(cancelled.status, 200);
    expect((cancelled.value['data'] as Map)['status'], 'cancelled');
    expect(fixture.probe.holdTls!.isCompleted, isTrue);
  });
}
