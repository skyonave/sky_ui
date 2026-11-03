import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:dart_frog/dart_frog.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'config.dart';
import 'core_manager.dart';
import 'errors.dart';
import 'panel/service.dart';
import 'panel/client_exporter.dart';
import 'system_monitor.dart';
import 'core_updates.dart';
import 'panel_updates.dart';
import 'process_runner.dart';
import 'auth/owner_auth.dart';
import 'maintenance.dart';
import 'sni_scanner.dart';

Handler createApplication(
  ServerConfig config,
  CoreManager manager, {
  PanelService? panel,
  OwnerAuth? auth,
  MaintenanceService? maintenance,
  CoreUpdates? coreUpdates,
  PanelUpdates? panelUpdates,
}) {
  if (config.requireOwnerAuth && auth == null)
    throw StateError('Owner authentication is required.');
  Response failure(
    String code,
    int status, {
    Map<String, String> fields = const {},
  }) => Response.json(
    statusCode: status,
    body: {'error': ApiError(code, fields: fields).toJson()},
  );
  final router = Router(
    notFoundHandler: (_) => failure('not_found', 404),
    methodNotAllowedHandler: (_) => failure('method_not_allowed', 405),
  );
  final system = SystemMonitor(config.dataDirectory);
  final sniScanner = SniScanner();
  final updates = coreUpdates ?? CoreUpdates();
  final instances = panel?.managers ?? {manager.core.id: manager};
  final applicationUpdates =
      panelUpdates ?? PanelUpdates(const NativeCommandRunner());
  router.get(
    '/api/v1/panel-update',
    (context) async => Response.json(
      body: {
        'data': (await applicationUpdates.get(
          refresh: context.request.uri.queryParameters['refresh'] == 'true',
        )).toJson(),
      },
    ),
  );
  if (maintenance != null) {
    router.get(
      '/api/v1/maintenance',
      (_) async => Response.json(
        body: {'data': (await maintenance.snapshot()).toJson()},
      ),
    );
    router.post('/api/v1/maintenance', (context) async {
      if ((context.request.headers['content-type'] ?? '')
              .split(';')
              .first
              .trim() !=
          'application/json') {
        throw const ApiException('json_required', status: 415);
      }
      final bytes = <int>[];
      await for (final chunk in context.request.bytes()) {
        if (bytes.length + chunk.length > 4096)
          throw const ApiException('request_too_large', status: 413);
        bytes.addAll(chunk);
      }
      Map<String, dynamic> value;
      try {
        value = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      } on Object {
        throw const ApiException('request_invalid', status: 400);
      }
      if (value['confirmed'] != true ||
          value['action'] is! String ||
          (value['backupId'] != null && value['backupId'] is! String) ||
          (value['core'] != null && value['core'] is! String) ||
          (value['tag'] != null && value['tag'] is! String)) {
        throw const ApiException('request_invalid', status: 400);
      }
      final selectedCore = value['core'] as String? ?? manager.core.coreId;
      final selectedManager = instances.values
          .where((m) => m.core.coreId == selectedCore)
          .firstOrNull;
      if (selectedManager == null)
        throw const ApiException('core_unsupported', status: 422);
      final job = await selectedManager.exclusive((_) async {
        if (panel != null && !await panel.isSynchronized()) {
          throw const ApiException('configuration_out_of_sync', status: 409);
        }
        if (value['action'] == 'panel-update') {
          await applicationUpdates.requireApproved(
            value['tag'] as String? ?? '',
          );
        }
        if (['remove', 'install'].contains(value['action'])) {
          final installed = (await selectedManager.snapshot()).binaryAvailable;
          if (installed == (value['action'] == 'install')) {
            throw ApiException(
              installed ? 'core_already_installed' : 'binary_missing',
              status: 409,
            );
          }
        }
        if (['update', 'install'].contains(value['action'])) {
          await updates.requireApproved(
            selectedCore,
            value['tag'] as String? ?? '',
          );
        }
        return maintenance.submit(
          value['action'] as String,
          backupId: value['backupId'] as String?,
          core: ['update', 'install', 'remove'].contains(value['action'])
              ? selectedCore
              : null,
          tag: value['tag'] as String?,
        );
      });
      return Response.json(statusCode: 202, body: {'data': job.toJson()});
    });
    router.get('/api/v1/backups/<id>/download', (
      RequestContext context,
      String id,
    ) async {
      final file = await maintenance.archive(id);
      return Response.stream(
        body: file.openRead(),
        headers: {
          'content-type': 'application/gzip',
          'content-disposition': 'attachment; filename=sky-ui-$id.tar.gz',
        },
      );
    });
  }
  if (auth != null) {
    Future<Map<String, dynamic>> authBody(RequestContext context) async {
      if ((context.request.headers['content-type'] ?? '')
              .split(';')
              .first
              .trim()
              .toLowerCase() !=
          'application/json')
        throw const ApiException('json_required', status: 415);
      final bytes = <int>[];
      await for (final chunk in context.request.bytes()) {
        if (bytes.length + chunk.length > 4096)
          throw const ApiException('request_too_large', status: 413);
        bytes.addAll(chunk);
      }
      try {
        final value = jsonDecode(utf8.decode(bytes));
        if (value is Map<String, dynamic>) return value;
      } on Object {}
      throw const ApiException('request_invalid', status: 400);
    }

    OwnerIdentity identity(RequestContext c) =>
        auth.identify(c.request.headers['cookie']) ??
        (throw const ApiException('auth_required', status: 401));
    String ip(RequestContext c) {
      final value = config.gatewaySecret.isNotEmpty
          ? c.request.headers['x-sky-ui-client-ip']
          : null;
      return InternetAddress.tryParse(value ?? '')?.address ?? '127.0.0.1';
    }

    String agent(RequestContext c) => c.request.headers['user-agent'] ?? '';
    Response signed(OwnerLogin result) => Response.json(
      body: {'data': result.state.toJson()},
      headers: {'set-cookie': auth.cookie(result.token)},
    );
    router.get(
      '/api/v1/auth/session',
      (c) => Response.json(
        body: {
          'data': auth
              .state(auth.identify(c.request.headers['cookie']))
              .toJson(),
        },
      ),
    );
    router.post('/api/v1/auth/login', (c) async {
      final body = await authBody(c);
      if (body['username'] is! String || body['password'] is! String)
        throw const ApiException('request_invalid', status: 400);
      return signed(
        await auth.login(
          body['username'] as String,
          body['password'] as String,
          ip(c),
          agent(c),
        ),
      );
    });
    router.post('/api/v1/auth/logout', (c) async {
      await authBody(c);
      auth.revoke(identity(c).id);
      return Response.json(
        body: {'data': auth.state(null).toJson()},
        headers: {'set-cookie': auth.cookie(null)},
      );
    });
    router.put('/api/v1/auth/owner', (c) async {
      final who = identity(c), body = await authBody(c);
      if (body['currentPassword'] is! String ||
          (body['username'] == null && body['password'] == null) ||
          (body['username'] != null && body['username'] is! String) ||
          (body['password'] != null && body['password'] is! String))
        throw const ApiException('request_invalid', status: 400);
      return signed(
        await auth.change(
          who,
          currentPassword: body['currentPassword'] as String,
          username: body['username'] as String?,
          password: body['password'] as String?,
          ip: ip(c),
          agent: agent(c),
        ),
      );
    });
    router.get(
      '/api/v1/auth/sessions',
      (c) => Response.json(
        body: {
          'data': auth.sessions(identity(c)).map((s) => s.toJson()).toList(),
        },
      ),
    );
    router.post('/api/v1/auth/sessions/revoke-others', (c) async {
      final who = identity(c), body = await authBody(c);
      if (body['confirmed'] != true)
        throw const ApiException('request_invalid', status: 400);
      auth.revokeOthers(who);
      return Response.json(
        body: {'data': auth.sessions(who).map((s) => s.toJson()).toList()},
      );
    });
    router.delete('/api/v1/auth/sessions/<id>', (
      RequestContext c,
      String id,
    ) async {
      final who = identity(c);
      await authBody(c);
      if (!auth.sessions(who).any((s) => s.id == id))
        throw const ApiException('not_found', status: 404);
      auth.revoke(id);
      return Response.json(
        body: {
          'data': id == who.id
              ? []
              : auth.sessions(who).map((s) => s.toJson()).toList(),
        },
        headers: {if (id == who.id) 'set-cookie': auth.cookie(null)},
      );
    });
  }
  router.get(
    '/api/v1/system',
    (_) async =>
        Response.json(body: {'data': (await system.snapshot()).toJson()}),
  );
  router.get('/api/v1/updates/<core>', (
    RequestContext context,
    String core,
  ) async {
    final owner = instances.values
        .where((m) => m.core.coreId == core)
        .firstOrNull;
    final installed = owner == null ? null : (await owner.snapshot()).version;
    return Response.json(
      body: {'data': (await updates.get(core, installed)).toJson()},
    );
  });
  router.get('/api/v1/cores/<id>/logs/events', (
    RequestContext context,
    String id,
  ) {
    final manager = instances[id];
    if (manager == null) return failure('instance_not_found', 404);
    Timer? timer;
    String? previous;
    var ticks = 0;
    late StreamController<List<int>> stream;
    void emit() {
      if (auth != null &&
          auth.identify(context.request.headers['cookie']) == null) {
        stream.add(utf8.encode('event: auth_expired\ndata: {}\n\n'));
        timer?.cancel();
        unawaited(stream.close());
        return;
      }
      final json = jsonEncode(manager.logs().map((v) => v.toJson()).toList());
      if (json != previous) {
        previous = json;
        stream.add(utf8.encode('data: $json\n\n'));
      } else if (++ticks % 30 == 0) {
        stream.add(utf8.encode(': keepalive\n\n'));
      }
    }

    stream = StreamController<List<int>>(
      onListen: () {
        emit();
        if (stream.isClosed) return;
        timer = Timer.periodic(
          const Duration(milliseconds: 500),
          (_) => emit(),
        );
      },
      onCancel: () {
        timer?.cancel();
      },
    );
    return Response.stream(
      bufferOutput: false,
      body: stream.stream,
      headers: {
        'content-type': 'text/event-stream',
        'cache-control': 'no-store',
        'x-accel-buffering': 'no',
      },
    );
  });
  router.delete('/api/v1/cores/<id>/logs', (
    RequestContext context,
    String id,
  ) async {
    final manager = instances[id];
    if (manager == null) return failure('instance_not_found', 404);
    if ((context.request.headers['content-type'] ?? '')
            .split(';')
            .first
            .trim()
            .toLowerCase() !=
        'application/json')
      return failure('json_required', 415);
    final bytes = <int>[];
    await for (final chunk in context.request.bytes()) {
      if (bytes.length + chunk.length > 1024)
        return failure('request_too_large', 413);
      bytes.addAll(chunk);
    }
    try {
      final body = jsonDecode(utf8.decode(bytes));
      if (body is! Map || body['confirmed'] != true)
        return failure('request_invalid', 400);
    } on Object {
      return failure('request_invalid', 400);
    }
    await manager.clearLogs();
    return Response.json(
      body: {'data': manager.logs().map((v) => v.toJson()).toList()},
    );
  });
  router.get(
    '/api/v1/health',
    (_) => Response.json(
      body: {
        'status': 'ok',
        'version': skyUiVersion,
        'authentication': config.gatewaySecret.isEmpty
            ? 'loopback-only'
            : 'gateway',
      },
    ),
  );
  router.get(
    '/api/v1/cores',
    (_) async => Response.json(
      body: {
        'data': [
          for (final owner in instances.values)
            (await owner.snapshot()).toJson(),
        ],
      },
    ),
  );
  router.get('/api/v1/cores/<id>', (RequestContext context, String id) async {
    final manager = instances[id];
    if (manager == null) return failure('instance_not_found', 404);
    return Response.json(body: {'data': (await manager.snapshot()).toJson()});
  });
  router.get('/api/v1/cores/<id>/logs', (RequestContext context, String id) {
    final manager = instances[id];
    if (manager == null) return failure('instance_not_found', 404);
    return Response.json(
      body: {'data': manager.logs().map((v) => v.toJson()).toList()},
    );
  });
  router.post('/api/v1/cores/<id>/actions/<action>', (
    RequestContext context,
    String id,
    String action,
  ) async {
    final manager = instances[id];
    if (manager == null) return failure('instance_not_found', 404);
    final operation = CoreOperation.values
        .where((v) => v.name == action)
        .firstOrNull;
    if (operation == null ||
        ![
          CoreOperation.start,
          CoreOperation.stop,
          CoreOperation.restart,
          CoreOperation.validate,
        ].contains(operation)) {
      return failure('operation_unsupported', 422);
    }
    final type = context.request.headers['content-type'] ?? '';
    if (type.split(';').first.trim().toLowerCase() != 'application/json')
      return failure('json_required', 415);
    return Response.json(
      body: {
        'data':
            (await (panel?.executeCore(operation, instanceId: id) ??
                    manager.execute(operation)))
                .toJson(),
      },
    );
  });
  if (panel != null) {
    Future<Map<String, dynamic>> body(RequestContext context) async {
      if ((context.request.headers['content-type'] ?? '')
              .split(';')
              .first
              .trim()
              .toLowerCase() !=
          'application/json') {
        throw const ApiException('json_required', status: 415);
      }
      final bytes = <int>[];
      await for (final chunk in context.request.bytes()) {
        if (bytes.length + chunk.length > 65536)
          throw const ApiException('request_too_large', status: 413);
        bytes.addAll(chunk);
      }
      try {
        final value = jsonDecode(utf8.decode(bytes));
        if (value is! Map<String, dynamic> ||
            value['revision'] is! int ||
            (value['revision'] as int) < 0) {
          throw const FormatException();
        }
        return value;
      } on Object {
        throw const ApiException('request_invalid', status: 400);
      }
    }

    Response data(PanelSnapshot snapshot) =>
        Response.json(body: {'data': snapshot.toJson()});
    router.get('/api/v1/panel', (_) async => data(await panel.snapshot()));
    router.get(
      '/api/v1/connection-tools/sni',
      (_) => Response.json(body: {'data': sniScanner.snapshot}),
    );
    router.post('/api/v1/connection-tools/sni', (context) async {
      final value = await body(context);
      if (value['revision'] != panel.repository.revision)
        throw const ApiException('state_changed', status: 409);
      return Response.json(
        statusCode: 202,
        body: {'data': sniScanner.start(panel.repository.read().address)},
      );
    });
    router.delete('/api/v1/connection-tools/sni/<id>', (
      RequestContext context,
      String id,
    ) {
      sniScanner.cancel(id);
      return Response.json(body: {'data': sniScanner.snapshot});
    });
    router.post('/api/v1/connection-tools/generate', (context) async {
      final value = await body(context);
      if (value['core'] is! String ||
          value['protocol'] is! String ||
          value['field'] is! String ||
          value['values'] is! Map ||
          (value['values'] as Map).length > 256 ||
          (value['values'] as Map).entries.any(
            (e) => e.key is! String || e.value is! String,
          )) {
        throw const ApiException('request_invalid', status: 400);
      }
      return Response.json(
        body: {
          'data': await panel.generateConnectionFields(
            value['revision'] as int,
            value['core'] as String,
            value['protocol'] as String,
            value['field'] as String,
            Map<String, String>.from(value['values'] as Map),
          ),
        },
      );
    });
    Future<Response> saveConnection(
      RequestContext context, {
      String? id,
    }) async {
      final value = await body(context);
      Connection input;
      try {
        input = Connection.fromJson(
          Map<String, dynamic>.from(value['connection'] as Map),
        );
      } on Object {
        throw const ApiException('request_invalid', status: 400);
      }
      return data(
        await panel.saveConnection(value['revision'] as int, input, id: id),
      );
    }

    Future<Response> saveRecipient(RequestContext context, {String? id}) async {
      final value = await body(context);
      Recipient input;
      try {
        input = Recipient.fromJson(
          Map<String, dynamic>.from(value['recipient'] as Map),
        );
      } on Object {
        throw const ApiException('request_invalid', status: 400);
      }
      return data(
        await panel.saveRecipient(value['revision'] as int, input, id: id),
      );
    }

    router.post('/api/v1/connections', (context) => saveConnection(context));
    router.put(
      '/api/v1/connections/<id>',
      (RequestContext context, String id) => saveConnection(context, id: id),
    );
    router.delete('/api/v1/connections/<id>', (
      RequestContext context,
      String id,
    ) async {
      final value = await body(context);
      return data(await panel.deleteConnection(value['revision'] as int, id));
    });
    router.post('/api/v1/recipients', (context) => saveRecipient(context));
    router.put(
      '/api/v1/recipients/<id>',
      (RequestContext context, String id) => saveRecipient(context, id: id),
    );
    router.delete('/api/v1/recipients/<id>', (
      RequestContext context,
      String id,
    ) async {
      final value = await body(context);
      return data(await panel.deleteRecipient(value['revision'] as int, id));
    });
    router.put('/api/v1/settings', (context) async {
      final value = await body(context);
      if (value['serverName'] is! String || value['address'] is! String)
        throw const ApiException('request_invalid', status: 400);
      return data(
        await panel.saveSettings(
          value['revision'] as int,
          value['serverName'] as String,
          value['address'] as String,
        ),
      );
    });
    router.get(
      '/api/v1/recipients/<id>/share',
      (RequestContext context, String id) async =>
          Response.json(body: {'data': (await panel.share(id)).toJson()}),
    );
    router.get('/s/<filename>', (
      RequestContext context,
      String filename,
    ) async {
      if (!RegExp(r'^[A-Za-z0-9_-]{43}(?:\.(yaml|txt))?$').hasMatch(filename))
        return failure('not_found', 404);
      final format = filename.endsWith('.yaml')
          ? 'clash'
          : filename.endsWith('.txt')
          ? 'v2ray'
          : subscriptionFormatFor(context.request.headers['user-agent'] ?? '');
      return Response(
        body: await panel.subscription(
          filename.substring(0, 43),
          format: format,
          clientId: subscriptionClientFor(
            context.request.headers['user-agent'] ?? '',
          ),
        ),
        headers: {
          'content-type': format == 'v2ray'
              ? 'text/plain; charset=utf-8'
              : 'application/yaml; charset=utf-8',
          'content-disposition': format == 'v2ray'
              ? 'inline; filename=Sky-UI.txt'
              : 'inline; filename=Sky-UI.yaml',
          'profile-update-interval': '6',
          'vary': 'User-Agent',
          'x-robots-tag': 'noindex, nofollow, noarchive',
        },
      );
    });
  }
  const assets = {
    '/': ('index.html', 'text/html; charset=utf-8'),
    '/index.html': ('index.html', 'text/html; charset=utf-8'),
    '/main.dart.js': ('main.dart.js', 'application/javascript; charset=utf-8'),
    '/styles.css': ('styles.css', 'text/css; charset=utf-8'),
    '/fonts/PxPlus_IBM_VGA8.ttf': ('fonts/PxPlus_IBM_VGA8.ttf', 'font/ttf'),
    '/fonts/LICENSE-IBM-VGA.txt': (
      'fonts/LICENSE-IBM-VGA.txt',
      'text/plain; charset=utf-8',
    ),
    '/fonts/ATTRIBUTION.txt': (
      'fonts/ATTRIBUTION.txt',
      'text/plain; charset=utf-8',
    ),
  };
  for (final entry in assets.entries) {
    router.get(entry.key, (_) async {
      final file = File('${config.publicDirectory}/${entry.value.$1}');
      if (!await file.exists()) return failure('asset_missing', 404);
      return Response.stream(
        body: file.openRead(),
        headers: {'content-type': entry.value.$2},
      );
    });
  }

  return (context) async {
    final request = context.request;
    final origin = request.headers['origin'];
    // requestedUri may use proxy-forwarded authority; validate the actual Host.
    final host = request.headers['host'] ?? '';
    final publicAssetRead =
        (request.method == HttpMethod.get ||
            request.method == HttpMethod.head) &&
        assets.containsKey('/${request.url.path}');
    final publicRead =
        (request.method == HttpMethod.get ||
            request.method == HttpMethod.head) &&
        RegExp(
          r'^s/[A-Za-z0-9_-]{43}(?:\.(yaml|txt))?$',
        ).hasMatch(request.url.path);
    Response response;
    try {
      final healthRead =
          request.method == HttpMethod.get &&
          request.url.path == 'api/v1/health';
      if (config.gatewaySecret.isNotEmpty &&
          !healthRead &&
          !gatewayCredentialMatches(
            request.headers['x-sky-ui-gateway'] ?? '',
            config.gatewaySecret,
          )) {
        response = failure('gateway_auth_required', 401);
      } else if (!RegExp(r'^127\.0\.0\.1(?::[0-9]{1,5})?$').hasMatch(host) ||
          (!publicRead &&
              ((origin != null && !config.allowedOrigins.contains(origin)) ||
                  (request.headers['sec-fetch-site'] == 'cross-site' &&
                      !publicAssetRead)))) {
        response = failure('origin_forbidden', 403);
      } else {
        if (auth != null) {
          final path = request.url.path;
          final reading =
              request.method == HttpMethod.get ||
              request.method == HttpMethod.head;
          final login =
              path == 'api/v1/auth/login' && request.method == HttpMethod.post;
          final anonymous =
              publicRead ||
              healthRead ||
              (reading &&
                  (assets.containsKey('/$path') ||
                      path == 'api/v1/auth/session')) ||
              login;
          if (!anonymous) {
            final identity = auth.identify(request.headers['cookie']);
            if (identity == null)
              throw ApiException(
                auth.configured ? 'auth_required' : 'auth_not_configured',
                status: auth.configured ? 401 : 503,
              );
            if (!reading)
              auth.csrf(identity, request.headers['x-sky-ui-csrf'] ?? '');
          }
        }
        if (maintenance?.busy == true &&
            request.method != HttpMethod.get &&
            request.method != HttpMethod.head &&
            !request.url.path.startsWith('api/v1/auth/')) {
          throw const ApiException('maintenance_busy', status: 409);
        }
        response = await router(context);
      }
    } on ApiException catch (e) {
      response = failure(e.code, e.status, fields: e.fields);
    } on Object {
      response = failure('internal_error', 500);
    }
    return response.copyWith(
      headers: {
        ...response.headers,
        'cache-control': 'no-store',
        'x-content-type-options': 'nosniff',
        'referrer-policy': 'no-referrer',
        'content-security-policy':
            "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
      },
    );
  };
}

bool gatewayCredentialMatches(String value, String expected) {
  if (value.length != expected.length) return false;
  var difference = 0;
  for (var i = 0; i < expected.length; i++) {
    difference |= value.codeUnitAt(i) ^ expected.codeUnitAt(i);
  }
  return difference == 0;
}
