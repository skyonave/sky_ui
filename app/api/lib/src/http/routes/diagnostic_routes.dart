import 'dart:convert';
import 'package:dart_frog/dart_frog.dart';
import '../../application/connections/diagnostics_service.dart';
import '../../shared/api_exception.dart';

void registerDiagnosticRoutes(
  Router router,
  ConnectionDiagnosticsService diagnostics,
) {
  router.post('/api/v1/connections/<connection>/diagnostics', (
    RequestContext context,
    String connection,
  ) async {
    if ((context.request.headers['content-type'] ?? '')
            .split(';')
            .first
            .trim()
            .toLowerCase() !=
        'application/json')
      throw const ApiException('json_required', status: 415);
    final bytes = <int>[];
    await for (final chunk in context.request.bytes()) {
      if (bytes.length + chunk.length > 1024)
        throw const ApiException('request_too_large', status: 413);
      bytes.addAll(chunk);
    }
    int revision;
    try {
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map ||
          value.length != 1 ||
          value['revision'] is! int ||
          value['revision'] < 0)
        throw const FormatException();
      revision = value['revision'] as int;
    } on Object {
      throw const ApiException('request_invalid', status: 400);
    }
    final report = await diagnostics.start(connection, revision);
    return Response.json(statusCode: 202, body: {'data': report.toJson()});
  });
  router.get(
    '/api/v1/connections/<connection>/diagnostics/<id>',
    (RequestContext context, String connection, String id) =>
        Response.json(body: {'data': diagnostics.get(connection, id).toJson()}),
  );
  router.delete(
    '/api/v1/connections/<connection>/diagnostics/<id>',
    (RequestContext context, String connection, String id) => Response.json(
      body: {'data': diagnostics.cancel(connection, id).toJson()},
    ),
  );
}
