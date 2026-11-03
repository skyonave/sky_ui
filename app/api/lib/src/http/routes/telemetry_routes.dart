import 'package:dart_frog/dart_frog.dart';

import '../../bootstrap/server_config.dart';
import '../../features/telemetry/system_monitor.dart';

void registerTelemetryRoutes(
  Router router,
  ServerConfig config,
  SystemMonitor system,
) {
  router.get(
    '/api/v1/system',
    (_) async =>
        Response.json(body: {'data': (await system.snapshot()).toJson()}),
  );
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
}
