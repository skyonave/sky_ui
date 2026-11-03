import 'package:sky_ui_shared/sky_ui_shared.dart';

import 'managed_core.dart';

class BinaryProbe {
  const BinaryProbe(this.available, this.version);
  final bool available;
  final String? version;
}

abstract interface class CoreAdapter {
  String get id;
  String get name;
  Future<BinaryProbe> probe(ManagedCore core);
  Future<void> validate(ManagedCore core);
  Future<bool> controllerReady(ManagedCore core);
  Future<void> observeLogs(ManagedCore core);
  List<CoreLogEntry> get logs;
  void clearLogs();
  Future<void> close();
}

class ServiceObservation {
  const ServiceObservation(
    this.state, {
    this.loaded = true,
    this.memoryBytes,
    this.processId,
    this.error,
  });
  final CoreProcessState state;
  final bool loaded;
  final int? memoryBytes;
  final int? processId;
  final ApiError? error;
}

abstract interface class ProcessSupervisor {
  bool get supported;
  Future<ServiceObservation> inspect(ManagedCore core);
  Future<void> execute(ManagedCore core, CoreOperation operation);
}
