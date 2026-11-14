import 'dart:async';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import '../access/records.dart';

/// Adapters project their own bind/transport semantics; no native document escapes.
abstract interface class ConnectionDiagnosticsCodec {
  ConnectionDiagnosticPlan diagnosticPlan(
    PanelData data,
    StoredConnection connection,
  );
}

class DiagnosticListener {
  const DiagnosticListener({
    required this.host,
    required this.port,
    required this.udp,
    this.interfaceName,
  });
  final String host;
  final int port;
  final bool udp;
  final String? interfaceName;
  Map<String, String> get details => {
    'endpoint': '${host.contains(':') ? '[$host]' : host}:$port',
    'transport': udp ? 'UDP' : 'TCP',
    if (interfaceName != null) 'interface': interfaceName!,
  };
}

class DiagnosticTlsTarget {
  const DiagnosticTlsTarget({
    required this.host,
    required this.port,
    required this.serverName,
    required this.remote,
    this.tls13 = false,
  });
  final String host, serverName;
  final int port;
  final bool remote, tls13;
  Map<String, String> get details => {
    'target': '${host.contains(':') ? '[$host]' : host}:$port',
    'sni': serverName,
    'purpose': remote ? 'REALITY' : 'TLS',
  };
}

class ConnectionDiagnosticPlan {
  const ConnectionDiagnosticPlan({
    this.listeners = const [],
    this.tls,
    this.tlsSkipCode = 'not_applicable',
  });
  final List<DiagnosticListener> listeners;
  final DiagnosticTlsTarget? tls;
  final String tlsSkipCode;
}

class DiagnosticProbeResult {
  const DiagnosticProbeResult(this.state, this.code, [this.details = const {}]);
  final DiagnosticState state;
  final String code;
  final Map<String, String> details;
  bool get passed => state == DiagnosticState.passed;
}

class DiagnosticResolution {
  const DiagnosticResolution(this.result, [this.addresses = const []]);
  final DiagnosticProbeResult result;
  final List<String> addresses;
}

/// A bounded observation from the managed ingress host, never from the panel host.
class RemoteDiagnosticSnapshot {
  const RemoteDiagnosticSnapshot({
    required this.installed,
    required this.state,
    required this.hash,
    required this.native,
    this.version = '',
    this.processId,
    this.listeners = const [],
  });
  final bool installed;
  final String state, hash, version;
  final int? processId;
  final DiagnosticProbeResult native;
  final List<DiagnosticListener> listeners;
}

abstract interface class RemoteConnectionDiagnostics {
  Future<RemoteDiagnosticSnapshot> inspect(
    String node,
    String core,
    DiagnosticCancellation cancellation,
  );
  DiagnosticNetworkProbe probe(String node, String core);
}

class DiagnosticCancelled implements Exception {
  const DiagnosticCancelled();
}

/// Cancels owned sockets/processes, including when a dialog closes mid-handshake.
class DiagnosticCancellation {
  bool cancelled = false;
  final _done = Completer<void>();
  Future<void> get whenCancelled => _done.future;
  final _callbacks = <void Function()>{};
  void check() {
    if (cancelled) throw const DiagnosticCancelled();
  }

  void add(void Function() callback) {
    if (cancelled) {
      callback();
    } else {
      _callbacks.add(callback);
    }
  }

  void remove(void Function() callback) => _callbacks.remove(callback);
  void cancel() {
    if (cancelled) return;
    cancelled = true;
    _done.complete();
    for (final callback in [..._callbacks]) {
      callback();
    }
    _callbacks.clear();
  }
}

abstract interface class DiagnosticNetworkProbe {
  Future<DiagnosticProbeResult> listener(
    DiagnosticListener listener,
    int? processId,
    DiagnosticCancellation cancellation,
  );
  Future<DiagnosticResolution> resolve(
    DiagnosticTlsTarget target,
    DiagnosticCancellation cancellation,
  );
  Future<DiagnosticProbeResult> tcp(
    DiagnosticTlsTarget target,
    List<String> addresses,
    DiagnosticCancellation cancellation,
  );
  Future<DiagnosticProbeResult> tls(
    DiagnosticTlsTarget target,
    String address,
    DiagnosticCancellation cancellation,
  );
}
