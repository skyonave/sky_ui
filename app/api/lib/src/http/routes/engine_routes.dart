import 'dart:async';
import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../application/access/panel_service.dart';
import '../../application/engines/core_manager.dart';
import '../../features/auth/owner_auth.dart';
import '../responses.dart';

void registerEngineRoutes(
  Router router,
  Map<String, CoreManager> instances,
  PanelService? panel,
  OwnerAuth? auth,
) {
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
}
