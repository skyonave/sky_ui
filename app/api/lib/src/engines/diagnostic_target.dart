import '../application/contracts/connection_diagnostics.dart';

/// Converts normalized adapter settings into a target, never client credentials.
ConnectionDiagnosticPlan diagnosticTargets({
  required List<DiagnosticListener> listeners,
  required Map<String, String> settings,
  String? realityTarget,
}) {
  final protection = settings['security'];
  if (protection == 'REALITY') {
    final parsed = Uri.tryParse('tcp://${realityTarget ?? ''}');
    if (parsed == null ||
        parsed.host.isEmpty ||
        !parsed.hasPort ||
        parsed.userInfo.isNotEmpty ||
        parsed.path.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment) {
      return ConnectionDiagnosticPlan(
        listeners: listeners,
        tlsSkipCode: 'target_invalid',
      );
    }
    return ConnectionDiagnosticPlan(
      listeners: listeners,
      tls: DiagnosticTlsTarget(
        host: parsed.host,
        port: parsed.port,
        serverName: settings['serverName'] ?? '',
        remote: true,
        tls13: true,
      ),
    );
  }
  if (protection == 'TLS') {
    final tcp = listeners.where((listener) => !listener.udp).firstOrNull;
    if (tcp == null)
      return ConnectionDiagnosticPlan(
        listeners: listeners,
        tlsSkipCode: listeners.isEmpty
            ? 'no_active_listeners'
            : 'quic_client_required',
      );
    return ConnectionDiagnosticPlan(
      listeners: listeners,
      tls: DiagnosticTlsTarget(
        host: tcp.host == '::'
            ? '::1'
            : tcp.host == '0.0.0.0'
            ? '127.0.0.1'
            : tcp.host,
        port: tcp.port,
        serverName: settings['serverName'] ?? '',
        remote: false,
      ),
    );
  }
  return ConnectionDiagnosticPlan(listeners: listeners);
}
