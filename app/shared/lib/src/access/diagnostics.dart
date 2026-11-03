enum DiagnosticState { pending, running, passed, warning, failed, skipped }

class DiagnosticCheck {
  const DiagnosticCheck({
    required this.id,
    required this.kind,
    this.state = DiagnosticState.pending,
    this.code = 'pending',
    this.details = const {},
    this.durationMs,
  });
  final String id, kind, code;
  final DiagnosticState state;
  final Map<String, String> details;
  final int? durationMs;
  bool get finished =>
      state != DiagnosticState.pending && state != DiagnosticState.running;
  DiagnosticCheck copyWith({
    DiagnosticState? state,
    String? code,
    Map<String, String>? details,
    int? durationMs,
  }) => DiagnosticCheck(
    id: id,
    kind: kind,
    state: state ?? this.state,
    code: code ?? this.code,
    details: details ?? this.details,
    durationMs: durationMs ?? this.durationMs,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'state': state.name,
    'code': code,
    'details': details,
    'durationMs': durationMs,
  };
  factory DiagnosticCheck.fromJson(Map<String, dynamic> value) =>
      DiagnosticCheck(
        id: value['id'] as String,
        kind: value['kind'] as String,
        state: DiagnosticState.values.byName(value['state'] as String),
        code: value['code'] as String,
        details: Map<String, String>.from(value['details'] as Map? ?? {}),
        durationMs: value['durationMs'] as int?,
      );
}

/// Server-side observations only; never a claim about a recipient's network.
class ConnectionDiagnostics {
  const ConnectionDiagnostics({
    required this.id,
    required this.connectionId,
    required this.connectionName,
    required this.coreId,
    required this.instanceId,
    required this.revision,
    required this.startedAt,
    required this.status,
    required this.checks,
    this.finishedAt,
  });
  final String id,
      connectionId,
      connectionName,
      coreId,
      instanceId,
      status,
      startedAt;
  final int revision;
  final String? finishedAt;
  final List<DiagnosticCheck> checks;
  bool get running => status == 'running';
  int get completed => checks.where((check) => check.finished).length;
  String get outcome => running
      ? 'running'
      : status == 'cancelled'
      ? 'cancelled'
      : checks.any((check) => check.state == DiagnosticState.failed)
      ? 'failed'
      : checks.any((check) => check.state == DiagnosticState.warning)
      ? 'warning'
      : 'passed';
  Map<String, Object?> toJson() => {
    'id': id,
    'connectionId': connectionId,
    'connectionName': connectionName,
    'coreId': coreId,
    'instanceId': instanceId,
    'revision': revision,
    'startedAt': startedAt,
    'finishedAt': finishedAt,
    'status': status,
    'checks': checks.map((check) => check.toJson()).toList(),
  };
  factory ConnectionDiagnostics.fromJson(Map<String, dynamic> value) =>
      ConnectionDiagnostics(
        id: value['id'] as String,
        connectionId: value['connectionId'] as String,
        connectionName: value['connectionName'] as String,
        coreId: value['coreId'] as String,
        instanceId: value['instanceId'] as String,
        revision: value['revision'] as int,
        startedAt: value['startedAt'] as String,
        finishedAt: value['finishedAt'] as String?,
        status: value['status'] as String,
        checks: (value['checks'] as List)
            .map(
              (v) =>
                  DiagnosticCheck.fromJson(Map<String, dynamic>.from(v as Map)),
            )
            .toList(),
      );
}
