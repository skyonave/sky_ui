import 'dart:async';
import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../application/access/panel_service.dart';
import '../../application/subscriptions/client_exporter.dart';
import '../../features/connections/sni_scanner.dart';
import '../../shared/api_exception.dart';
import '../responses.dart';

void registerAccessRoutes(
  Router router,
  PanelService panel,
  SniScanner sniScanner,
) {
  Future<Map<String, dynamic>> body(
    RequestContext context, {
    int limit = 65536,
    bool requireRevision = true,
  }) async {
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
      if (bytes.length + chunk.length > limit)
        throw const ApiException('request_too_large', status: 413);
      bytes.addAll(chunk);
    }
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic> ||
          requireRevision &&
              (value['revision'] is! int || (value['revision'] as int) < 0)) {
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
    '/api/v1/recipients/presence',
    (_) async => Response.json(body: {'data': await panel.presence.snapshot()}),
  );
  router.get(
    '/api/v1/cores/<id>/settings',
    (RequestContext context, String id) async =>
        Response.json(body: {'data': (await panel.coreSettings(id)).toJson()}),
  );
  router.put('/api/v1/cores/<id>/settings', (
    RequestContext context,
    String id,
  ) async {
    final value = await body(context);
    if (value.keys.any((k) => !{'revision', 'values'}.contains(k)) ||
        value['values'] is! Map ||
        (value['values'] as Map).length > 32 ||
        (value['values'] as Map).entries.any(
          (e) => e.key is! String || e.value is! String,
        ))
      throw const ApiException('request_invalid', status: 400);
    return data(
      await panel.saveCoreSettings(
        value['revision'] as int,
        id,
        Map<String, String>.from(value['values'] as Map),
      ),
    );
  });
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
  Future<Response> saveConnection(RequestContext context, {String? id}) async {
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
  router.post('/s/<token>', (RequestContext context, String token) async {
    const mediaType = 'application/vnd.sky-ui.relink-v1+json';
    if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token))
      return failure('not_found', 404);
    if (context.request.headers['accept'] != mediaType)
      return failure('export_unavailable', 406);
    final value = await body(context, limit: 1024, requireRevision: false);
    final installation = value['installation'];
    final name = value['name'];
    if (installation is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(installation) ||
        name is! String)
      return failure('request_invalid', 400);
    final device = await panel.enrollSubscription(token, installation, name);
    return Response(
      body: await panel.subscription(device, format: 'relink'),
      headers: {
        'content-type': '$mediaType; charset=utf-8',
        'x-robots-tag': 'noindex, nofollow, noarchive',
      },
    );
  });
  router.get('/s/<filename>', (RequestContext context, String filename) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{43}(?:\.(yaml|txt))?$').hasMatch(filename))
      return failure('not_found', 404);
    const relinkType = 'application/vnd.sky-ui.relink-v1+json';
    final format = filename.endsWith('.yaml')
        ? 'clash'
        : filename.endsWith('.txt')
        ? 'v2ray'
        : context.request.headers['accept'] == relinkType
        ? 'relink'
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
        'content-type': switch (format) {
          'relink' => '$relinkType; charset=utf-8',
          'v2ray' => 'text/plain; charset=utf-8',
          _ => 'application/yaml; charset=utf-8',
        },
        'content-disposition': switch (format) {
          'relink' => 'inline; filename=Sky-UI.json',
          'v2ray' => 'inline; filename=Sky-UI.txt',
          _ => 'inline; filename=Sky-UI.yaml',
        },
        'profile-update-interval': '6',
        'vary': 'Accept, User-Agent',
        'x-robots-tag': 'noindex, nofollow, noarchive',
      },
    );
  });
}
