import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

import '../../bootstrap/server_config.dart';
import '../../features/auth/owner_auth.dart';
import '../../shared/api_exception.dart';

void registerAuthRoutes(Router router, ServerConfig config, OwnerAuth auth) {
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
        'data': auth.state(auth.identify(c.request.headers['cookie'])).toJson(),
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
