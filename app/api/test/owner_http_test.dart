import 'dart:convert';
import 'dart:io';
import 'package:bcrypt/bcrypt.dart';
import 'package:dart_frog/dart_frog.dart';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/auth/owner_auth.dart';
import 'package:test/test.dart';
import 'core_manager_test.dart' show FakeAdapter, FakeSupervisor, fixtureCore;

void main() {
  late Directory directory;
  late OwnerAuth auth;
  late HttpServer server;
  late HttpClient client;
  late Uri base;
  const origin = 'https://owner.example',
      gateway = 'fixture-private-gateway',
      password = 'fixture-owner-password';
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sky-ui-auth-http-');
    final seed = File('${directory.path}/seed')
      ..writeAsStringSync(
        'admin ${BCrypt.hashpw(password, BCrypt.gensalt(logRounds: 4))}',
      );
    File(
      '${directory.path}/index.html',
    ).writeAsStringSync('<html>Sign in</html>');
    auth = OwnerAuth('${directory.path}/owner.sqlite', secure: true);
    await auth.initialize(seed.path);
    final adapter = FakeAdapter(),
        manager = CoreManager(
          core: fixtureCore(),
          adapters: {adapter.id: adapter},
          supervisor: FakeSupervisor(),
          stateDirectory: directory.path,
        );
    final config = ServerConfig(
      port: 0,
      webOrigin: Uri.parse(origin),
      publicDirectory: directory.path,
      dataDirectory: directory.path,
      core: fixtureCore(),
      gatewaySecret: gateway,
    );
    server = await serve(
      createApplication(config, manager, auth: auth),
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
    await directory.delete(recursive: true);
  });
  Future<({int status, Map<String, dynamic> data, String? cookie})> call(
    String path, {
    String method = 'GET',
    Map<String, Object?>? payload,
    String? cookie,
    String? csrf,
    String? requestOrigin,
    String? fetchSite,
    bool includeGateway = true,
  }) async {
    final request = await client.openUrl(method, base.resolve(path));
    if (includeGateway) request.headers.set('X-Sky-UI-Gateway', gateway);
    request.headers.set('X-Sky-UI-Client-IP', '203.0.113.5');
    if (cookie != null) request.headers.set('Cookie', cookie);
    if (csrf != null) request.headers.set('X-Sky-UI-CSRF', csrf);
    if (requestOrigin != null) request.headers.set('Origin', requestOrigin);
    if (fetchSite != null) request.headers.set('Sec-Fetch-Site', fetchSite);
    if (payload != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload));
    }
    final response = await request.close(),
        body = await utf8.decoder.bind(response).join();
    final parsed = body.startsWith('{')
        ? jsonDecode(body) as Map<String, dynamic>
        : <String, dynamic>{};
    return (
      status: response.statusCode,
      data: parsed['data'] is Map<String, dynamic>
          ? parsed['data'] as Map<String, dynamic>
          : parsed,
      cookie: response.headers.value('set-cookie')?.split(';').first,
    );
  }

  Future<({String cookie, String csrf, String id})> login() async {
    final response = await call(
      '/api/v1/auth/login',
      method: 'POST',
      requestOrigin: origin,
      payload: {'username': 'admin', 'password': password},
    );
    expect(response.status, 200);
    return (
      cookie: response.cookie!,
      csrf: response.data['csrf'] as String,
      id: response.data['sessionId'] as String,
    );
  }

  test(
    'private gateway, owner cookie, origin and CSRF are independent mandatory boundaries',
    () async {
      expect((await call('/')).status, 200);
      expect((await call('/api/v1/auth/session')).data['authenticated'], false);
      expect((await call('/api/v1/system')).status, 401);
      expect(
        (await call(
          '/api/v1/auth/login',
          method: 'POST',
          requestOrigin: 'https://hostile.example',
          payload: {'username': 'admin', 'password': password},
        )).status,
        403,
      );
      final session = await login();
      expect(
        (await call(
          '/api/v1/auth/sessions',
          cookie: session.cookie,
          includeGateway: false,
        )).status,
        401,
      );
      expect(
        (await call('/api/v1/auth/sessions', cookie: session.cookie)).status,
        200,
      );
      expect(
        (await call(
          '/api/v1/auth/logout',
          method: 'POST',
          cookie: session.cookie,
          payload: {},
        )).status,
        403,
      );
      expect(
        (await call(
          '/api/v1/auth/logout',
          method: 'POST',
          cookie: session.cookie,
          csrf: session.csrf,
          requestOrigin: 'https://hostile.example',
          payload: {},
        )).status,
        403,
      );
      expect(
        (await call(
          '/api/v1/auth/logout',
          method: 'POST',
          cookie: session.cookie,
          csrf: session.csrf,
          requestOrigin: origin,
          payload: {},
        )).status,
        200,
      );
      expect(
        (await call('/api/v1/auth/sessions', cookie: session.cookie)).status,
        401,
      );
    },
  );
  test(
    'public session bootstrap reveals no owner name or credentials',
    () async {
      final session = await login(),
          state = await call('/api/v1/auth/session', cookie: session.cookie);
      expect(state.data['username'], 'admin');
      expect(state.data['csrf'], session.csrf);
      final anonymous = await call('/api/v1/auth/session');
      expect(anonymous.data['username'], isNull);
      expect(anonymous.data['csrf'], isNull);
    },
  );

  test(
    'cross-site navigation can open login assets but cannot read sessions or private APIs',
    () async {
      expect((await call('/', fetchSite: 'cross-site')).status, 200);
      expect(
        (await call('/api/v1/auth/session', fetchSite: 'cross-site')).status,
        403,
      );
      final session = await login();
      expect(
        (await call(
          '/api/v1/auth/sessions',
          cookie: session.cookie,
          fetchSite: 'cross-site',
        )).status,
        403,
      );
    },
  );
  test('revoking a session closes its already-open live log stream', () async {
    final session = await login();
    final request = await client.getUrl(
      base.resolve('/api/v1/cores/primary/logs/events'),
    );
    request.headers.set('X-Sky-UI-Gateway', gateway);
    request.headers.set('Cookie', session.cookie);
    final response = await request.close();
    expect(response.statusCode, 200);
    final content = utf8.decoder.bind(response).join();
    auth.revoke(session.id);
    expect(
      await content.timeout(const Duration(seconds: 4)),
      contains('event: auth_expired'),
    );
    expect(
      (await call('/api/v1/auth/sessions', cookie: session.cookie)).status,
      401,
    );
  });
}
