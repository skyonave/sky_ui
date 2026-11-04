import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../application/access/panel_service.dart';
import '../../features/maintenance/panel_https.dart';
import '../../features/maintenance/service.dart';
import '../../shared/api_exception.dart';

void registerHttpsRoutes(
  Router router,
  PanelHttps https,
  MaintenanceService maintenance,
  PanelService panel,
) {
  router.get(
    '/api/v1/panel/https',
    (_) async =>
        Response.json(body: {'data': (await https.snapshot()).toJson()}),
  );
  router.post('/api/v1/panel/https', (context) async {
    if (!https.available)
      throw const ApiException('domain_setup_required', status: 409);
    final request = context.request;
    if (request.headers['content-type']
            ?.split(';')
            .first
            .trim()
            .toLowerCase() !=
        'application/json')
      throw const ApiException('json_required', status: 415);
    final bytes = <int>[];
    await for (final chunk in request.bytes()) {
      if (bytes.length + chunk.length > 2048)
        throw const ApiException('request_too_large', status: 413);
      bytes.addAll(chunk);
    }
    final Object? payload;
    try {
      payload = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const ApiException('request_invalid', status: 400);
    }
    if (payload is! Map ||
        payload.length != 3 ||
        payload['confirmed'] != true ||
        payload['domain'] is! String ||
        payload['expectedDomain'] is! String)
      throw const ApiException('request_invalid', status: 400);
    final domain = (payload['domain'] as String).trim().toLowerCase();
    if (!validPanelDomain(domain))
      throw const ApiException('domain_invalid', status: 422);
    if (payload['expectedDomain'] != https.domain)
      throw const ApiException('domain_state_changed', status: 409);
    if (domain == https.domain)
      throw const ApiException('domain_unchanged', status: 422);
    final job = await panel.registry.exclusive((_) async {
      await panel.deployment.checkRevision(panel.repository.revision);
      return maintenance.submit(
        'panel-https',
        domain: domain,
        expectedDomain: https.domain,
      );
    });
    return Response.json(statusCode: 202, body: {'data': job.toJson()});
  });
}
