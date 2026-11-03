enum CoreProcessState {
  unknown,
  inactive,
  activating,
  active,
  deactivating,
  failed,
  unavailable,
}

enum CoreDesiredState { unknown, running, stopped }

enum CoreOperation { status, validate, start, stop, restart, logs }

class ApiError {
  const ApiError(
    this.code, {
    this.parameters = const {},
    this.fields = const {},
  });
  final String code;
  final Map<String, Object?> parameters;
  final Map<String, String> fields;
  Map<String, Object?> toJson() => {
    'code': code,
    'parameters': parameters,
    if (fields.isNotEmpty) 'fields': fields,
  };
  factory ApiError.fromJson(Map<String, dynamic> json) => ApiError(
    json['code'] as String,
    parameters: Map<String, Object?>.from(json['parameters'] as Map? ?? {}),
    fields: Map<String, String>.from(json['fields'] as Map? ?? {}),
  );
}

class CoreSnapshot {
  const CoreSnapshot({
    required this.instanceId,
    required this.coreId,
    required this.name,
    required this.service,
    required this.platformSupported,
    required this.binaryAvailable,
    required this.processState,
    required this.desiredState,
    required this.controllerReady,
    required this.operations,
    this.version,
    this.memoryBytes,
    this.error,
  });
  final String instanceId;
  final String coreId;
  final String name;
  final String service;
  final bool platformSupported;
  final bool binaryAvailable;
  final CoreProcessState processState;
  final CoreDesiredState desiredState;
  final bool controllerReady;
  final List<CoreOperation> operations;
  final String? version;
  final int? memoryBytes;
  final ApiError? error;
  Map<String, Object?> toJson() => {
    'instanceId': instanceId,
    'coreId': coreId,
    'name': name,
    'service': service,
    'platformSupported': platformSupported,
    'binaryAvailable': binaryAvailable,
    'processState': processState.name,
    'desiredState': desiredState.name,
    'controllerReady': controllerReady,
    'operations': operations.map((v) => v.name).toList(),
    'version': version,
    'memoryBytes': memoryBytes,
    'error': error?.toJson(),
  };
  factory CoreSnapshot.fromJson(Map<String, dynamic> json) => CoreSnapshot(
    instanceId: json['instanceId'] as String,
    coreId: json['coreId'] as String,
    name: json['name'] as String,
    service: json['service'] as String,
    platformSupported: json['platformSupported'] as bool,
    binaryAvailable: json['binaryAvailable'] as bool,
    processState: CoreProcessState.values.byName(
      json['processState'] as String,
    ),
    desiredState: CoreDesiredState.values.byName(
      json['desiredState'] as String,
    ),
    controllerReady: json['controllerReady'] as bool,
    operations: (json['operations'] as List)
        .map((v) => CoreOperation.values.byName(v as String))
        .toList(),
    version: json['version'] as String?,
    memoryBytes: json['memoryBytes'] as int?,
    error: json['error'] == null
        ? null
        : ApiError.fromJson(Map<String, dynamic>.from(json['error'] as Map)),
  );
}

class CoreLogEntry {
  const CoreLogEntry({
    required this.time,
    required this.level,
    required this.message,
    required this.source,
  });
  final DateTime time;
  final String level;
  final String message;
  final String source;
  Map<String, Object?> toJson() => {
    'time': time.toUtc().toIso8601String(),
    'level': level,
    'message': message,
    'source': source,
  };
  factory CoreLogEntry.fromJson(Map<String, dynamic> json) => CoreLogEntry(
    time: DateTime.parse(json['time'] as String),
    level: json['level'] as String,
    message: json['message'] as String,
    source: json['source'] as String,
  );
}
