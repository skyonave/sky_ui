import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:dart_frog/dart_frog.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'config.dart';
import 'core_manager.dart';
import 'errors.dart';
import 'panel/service.dart';
import 'system_monitor.dart';
import 'core_releases.dart';

Handler createApplication(
  ServerConfig config,
  CoreManager manager, {
  PanelService? panel,
}) {
  Response failure(String code, int status) => Response.json(
    statusCode: status,
    body: {'error': ApiError(code).toJson()},
  );
  final router = Router(
    notFoundHandler: (_) => failure('not_found', 404),
    methodNotAllowedHandler: (_) => failure('method_not_allowed', 405),
  );
  final system = SystemMonitor(config.dataDirectory);
  final releases = CoreReleases();
  router.get(
    '/api/v1/system',
    (_) async =>
        Response.json(body: {'data': (await system.snapshot()).toJson()}),
  );
  router.get('/api/v1/releases/<core>', (
    RequestContext context,
    String core,
  ) async {
    final installed = core == manager.core.coreId
        ? (await manager.snapshot()).version
        : null;
    return Response.json(
      body: {'data': (await releases.get(core, installed)).toJson()},
    );
  });
  router.get('/api/v1/cores/<id>/logs/events', (
    RequestContext context,
    String id,
  ) {
    if (id != manager.core.id) return failure('instance_not_found', 404);
    Timer? timer;
    String? previous;
    var ticks = 0;
    late StreamController<List<int>> stream;
    void emit() {
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
    if (id != manager.core.id) return failure('instance_not_found', 404);
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
        'data': [(await manager.snapshot()).toJson()],
      },
    ),
  );
  router.get('/api/v1/cores/<id>', (RequestContext context, String id) async {
    if (id != manager.core.id) return failure('instance_not_found', 404);
    return Response.json(body: {'data': (await manager.snapshot()).toJson()});
  });
  router.get('/api/v1/cores/<id>/logs', (RequestContext context, String id) {
    if (id != manager.core.id) return failure('instance_not_found', 404);
    return Response.json(
      body: {'data': manager.logs().map((v) => v.toJson()).toList()},
    );
  });
  router.post('/api/v1/cores/<id>/actions/<action>', (
    RequestContext context,
    String id,
    String action,
  ) async {
    if (id != manager.core.id) return failure('instance_not_found', 404);
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
            (await (panel?.executeCore(operation) ??
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
      if (!RegExp(r'^[A-Za-z0-9_-]{43}\.yaml$').hasMatch(filename))
        return failure('not_found', 404);
      return Response(
        body: await panel.subscription(filename.substring(0, 43)),
        headers: {
          'content-type': 'application/yaml; charset=utf-8',
          'content-disposition': 'inline; filename="sky-ui.yaml"',
          'profile-update-interval': '6',
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
    final publicRead =
        (request.method == HttpMethod.get ||
            request.method == HttpMethod.head) &&
        RegExp(r'^s/[A-Za-z0-9_-]{43}\.yaml$').hasMatch(request.url.path);
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
                  request.headers['sec-fetch-site'] == 'cross-site'))) {
        response = failure('origin_forbidden', 403);
      } else {
        response = await router(context);
      }
    } on ApiException catch (e) {
      response = failure(e.code, e.status);
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
