import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../application/access/panel_service.dart';
import '../../infrastructure/process/ssh_servers.dart';
import '../../shared/api_exception.dart';

void registerServerRoutes(
  Router router,
  SshServers? servers,
  PanelService? panel,
) {
  SshServers enabled() =>
      servers ?? (throw const ApiException('servers_disabled', status: 404));

  router.get(
    '/api/v1/servers',
    (_) => Response.json(
      body: {
        'enabled': servers != null,
        'data': [
          for (final node in servers?.list() ?? <ServerNode>[]) node.toJson(),
        ],
      },
    ),
  );
  router.post('/api/v1/servers', (context) async {
    final service = enabled();
    final value = await _body(context);
    final name = value['name'];
    final host = value['host'];
    final port = value['port'];
    final hostKey = value['hostKey'];
    final endpoint = value['endpoint'], relayAddress = value['relayAddress'];
    if (name is! String ||
        host is! String ||
        port is! int ||
        hostKey is! String ||
        endpoint != null && endpoint is! String ||
        relayAddress != null && relayAddress is! String) {
      throw const ApiException('request_invalid', status: 400);
    }
    final node = await service.add(
      name: name,
      host: host,
      port: port,
      hostKey: hostKey,
      endpoint: endpoint as String?,
      relayAddress: relayAddress as String?,
    );
    return Response.json(statusCode: 201, body: {'data': node.toJson()});
  });
  router.post('/api/v1/servers/<id>/operation', (
    RequestContext context,
    String id,
  ) async {
    final service = enabled();
    final value = await _body(context);
    final operation = ServerOperation.values
        .where((op) => op.name == value['operation'])
        .firstOrNull;
    if (operation == null) {
      throw const ApiException('request_invalid', status: 400);
    }
    return Response.json(body: {'data': await service.execute(id, operation)});
  });
  router.put('/api/v1/servers/<id>/endpoint', (
    RequestContext context,
    String id,
  ) async {
    final value = await _body(context);
    final endpoint = value['endpoint'];
    if (endpoint is! String)
      throw const ApiException('request_invalid', status: 400);
    if (panel == null)
      throw const ApiException('servers_disabled', status: 409);
    await panel.registry.exclusive((_) async {
      if (panel.repository.pending != null) {
        throw const ApiException('configuration_rollback_failed', status: 409);
      }
      await enabled().updateEndpoint(id, endpoint);
    });
    return Response.json(body: {'data': true});
  });
  router.post('/api/v1/servers/<id>/bootstrap', (
    RequestContext context,
    String id,
  ) async {
    final service = enabled();
    final value = await _body(context, limit: 20000);
    final user = value['user'],
        key = value['key'],
        password = value['password'];
    if (user is! String || key is! String || password is! String) {
      throw const ApiException('request_invalid', status: 400);
    }
    await service.bootstrap(id, user, key, password);
    return Response.json(body: {'data': true});
  });
  router.delete('/api/v1/servers/<id>', (
    RequestContext context,
    String id,
  ) async {
    final service = enabled();
    if (panel == null) {
      await service.remove(id);
    } else {
      await panel.registry.exclusive((_) async {
        if (panel.repository.pending != null ||
            panel.repository.read().namedRoutes.any(
              (r) => r.nodes.contains(id),
            ) ||
            panel.repository.read().connections.any(
              (c) => c.value.route.contains(id),
            )) {
          throw const ApiException('route_node_in_use', status: 409);
        }
        await service.remove(id);
      });
    }
    return Response.json(body: {'data': true});
  });
}

Future<Map<String, dynamic>> _body(
  RequestContext context, {
  int limit = 2048,
}) async {
  if (context.request.headers['content-type']?.split(';').first.trim() !=
      'application/json') {
    throw const ApiException('json_required', status: 415);
  }
  final bytes = <int>[];
  await for (final chunk in context.request.bytes()) {
    if (bytes.length + chunk.length > limit) {
      throw const ApiException('request_too_large', status: 413);
    }
    bytes.addAll(chunk);
  }
  try {
    final value = jsonDecode(utf8.decode(bytes));
    if (value is Map<String, dynamic>) return value;
  } on FormatException {
    // Report malformed JSON and invalid UTF-8 without echoing the request.
  }
  throw const ApiException('request_invalid', status: 400);
}
