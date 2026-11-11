import 'package:dart_frog/dart_frog.dart';

import '../application/access/panel_service.dart';
import '../application/connections/diagnostics_service.dart';
import '../application/engines/core_manager.dart';
import '../application/logs/panel_log.dart';
import '../bootstrap/server_config.dart';
import '../features/auth/owner_auth.dart';
import '../features/connections/sni_scanner.dart';
import '../features/maintenance/service.dart';
import '../features/maintenance/panel_https.dart';
import '../features/telemetry/system_monitor.dart';
import '../features/updates/core_updates.dart';
import '../features/updates/panel_updates.dart';
import '../infrastructure/process/command_runner.dart';
import '../infrastructure/process/ssh_servers.dart';
import '../infrastructure/network/diagnostic_probe.dart';
import 'responses.dart';
import 'routes/access_routes.dart';
import 'routes/asset_routes.dart';
import 'routes/diagnostic_routes.dart';
import 'routes/auth_routes.dart';
import 'routes/engine_routes.dart';
import 'routes/https_routes.dart';
import 'routes/maintenance_routes.dart';
import 'routes/server_routes.dart';
import 'routes/telemetry_routes.dart';
import 'routes/update_routes.dart';
import 'security.dart';

export 'security.dart' show gatewayCredentialMatches;

Handler createApplication(
  ServerConfig config,
  CoreManager manager, {
  PanelService? panel,
  OwnerAuth? auth,
  MaintenanceService? maintenance,
  CoreUpdates? coreUpdates,
  PanelUpdates? panelUpdates,
  ConnectionDiagnosticsService? diagnostics,
  SshServers? servers,
}) {
  if (config.requireOwnerAuth && auth == null)
    throw StateError('Owner authentication is required.');
  final router = Router(
    notFoundHandler: (_) => failure('not_found', 404),
    methodNotAllowedHandler: (_) => failure('method_not_allowed', 405),
  );
  final system = SystemMonitor(config.dataDirectory);
  final sniScanner = SniScanner();
  final updates = coreUpdates ?? CoreUpdates();
  final instances = panel?.managers ?? {manager.core.id: manager};
  final panelLog = panel?.log ?? PanelLog();
  panelLog.event('Sky UI API ready');
  final applicationUpdates =
      panelUpdates ?? PanelUpdates(const NativeCommandRunner());
  registerPanelUpdateRoutes(router, applicationUpdates);
  if (maintenance != null)
    registerMaintenanceRoutes(
      router,
      manager,
      instances,
      maintenance,
      updates,
      applicationUpdates,
      panel,
      panelLog,
    );
  if (auth != null) {
    registerAuthRoutes(router, config, auth);
    registerServerRoutes(router, servers, panel);
  }
  registerTelemetryRoutes(router, config, system);
  registerCoreUpdateRoutes(router, instances, updates);
  registerEngineRoutes(router, instances, panel, auth, panelLog);
  if (panel != null) {
    registerAccessRoutes(router, panel, sniScanner);
    if (maintenance != null)
      registerHttpsRoutes(
        router,
        PanelHttps(
          origin: config.webOrigin,
          additionalOrigins: config.additionalOrigins,
          certificatesDirectory: config.certificatesDirectory,
          enabled:
              maintenance.available &&
              auth != null &&
              config.gatewaySecret.isNotEmpty,
        ),
        maintenance,
        panel,
      );
    registerDiagnosticRoutes(
      router,
      diagnostics ??
          ConnectionDiagnosticsService(
            registry: panel.registry,
            repository: panel.repository,
            isSynchronized: panel.isSynchronized,
            probe: NativeDiagnosticProbe(),
          ),
    );
  }
  registerAssetRoutes(router, config);
  return secureApplication(
    config,
    router,
    auth: auth,
    maintenance: maintenance,
    panelLog: panelLog,
  );
}
