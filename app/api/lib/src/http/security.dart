import 'package:dart_frog/dart_frog.dart';

import '../bootstrap/server_config.dart';
import '../features/auth/owner_auth.dart';
import '../features/maintenance/service.dart';
import '../shared/api_exception.dart';
import 'responses.dart';
import 'routes/asset_routes.dart' show assets;

Handler secureApplication(
  ServerConfig config,
  Router router, {
  OwnerAuth? auth,
  MaintenanceService? maintenance,
}) {
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
