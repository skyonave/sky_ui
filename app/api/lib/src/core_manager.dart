import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'config.dart';
import 'cores/contracts.dart';
import 'errors.dart';

class CoreManager {
  CoreManager({
    required this.core,
    required Map<String, CoreAdapter> adapters,
    required this.supervisor,
    required this.stateDirectory,
    this.readyTimeout = const Duration(seconds: 8),
  }) : adapter =
           adapters[core.coreId] ??
           (throw const ApiException('core_unsupported', status: 422));
  final ManagedCore core;
  final CoreAdapter adapter;
  final ProcessSupervisor supervisor;
  final String stateDirectory;
  final Duration readyTimeout;
  CoreDesiredState desired = CoreDesiredState.unknown;
  ApiError? _operationError;
  Future<void> _tail = Future.value();
  final _events = <CoreLogEntry>[];

  Future<void> initialize() async {
    final file = File('$stateDirectory/${core.id}.json');
    if (await file.exists()) {
      final value =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (value['instanceId'] != core.id || value['coreId'] != core.coreId) {
        throw const FormatException(
          'Managed instance state identity mismatch.',
        );
      }
      desired = CoreDesiredState.values.byName(value['desiredState'] as String);
    }
  }

  Future<void> _remember(CoreDesiredState value) async {
    await Directory(stateDirectory).create(recursive: true);
    final file = File('$stateDirectory/${core.id}.json');
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      jsonEncode({
        'instanceId': core.id,
        'coreId': core.coreId,
        'desiredState': value.name,
      }),
      flush: true,
    );
    await temporary.rename(file.path);
    desired = value;
  }

  Future<void> restore() async {
    if (desired == CoreDesiredState.unknown) return;
    await execute(
      desired == CoreDesiredState.running
          ? CoreOperation.start
          : CoreOperation.stop,
    );
  }

  Future<CoreSnapshot> snapshot() async {
    ServiceObservation service;
    ApiError? error;
    try {
      service = await supervisor.inspect(core);
    } on ApiException catch (e) {
      service = ServiceObservation(
        CoreProcessState.unknown,
        loaded: false,
        error: e.error,
      );
    }
    var binary = const BinaryProbe(false, null);
    try {
      binary = await adapter.probe(core);
    } on ApiException catch (e) {
      error = e.error;
    }
    final ready =
        service.loaded &&
        service.state == CoreProcessState.active &&
        await adapter.controllerReady(core);
    if (ready) unawaited(adapter.observeLogs(core));
    error ??= _operationError ?? service.error;
    if (error == null && !binary.available)
      error = const ApiError('binary_missing');
    if (error == null && service.state == CoreProcessState.active && !ready)
      error = const ApiError('controller_not_ready');
    return CoreSnapshot(
      instanceId: core.id,
      coreId: core.coreId,
      name: adapter.name,
      service: core.service,
      platformSupported: supervisor.supported,
      binaryAvailable: binary.available,
      processState: service.state,
      desiredState: desired,
      controllerReady: ready,
      version: binary.version,
      memoryBytes: service.memoryBytes,
      error: error,
      operations: [
        CoreOperation.status,
        CoreOperation.logs,
        if (binary.available) CoreOperation.validate,
        if (supervisor.supported && service.loaded) ...[
          CoreOperation.stop,
          if (binary.available) ...[CoreOperation.start, CoreOperation.restart],
        ],
      ],
    );
  }

  // All lifecycle and configuration mutations share this queue.
  Future<T> exclusive<T>(Future<T> Function(CoreControl control) action) {
    final result = Completer<T>();
    _tail = _tail.then((_) async {
      final control = CoreControl._(this);
      try {
        result.complete(await action(control));
      } on Object catch (e, stack) {
        result.completeError(e, stack);
      } finally {
        control._active = false;
      }
    });
    return result.future;
  }

  Future<CoreSnapshot> execute(CoreOperation operation) =>
      exclusive((control) => control.execute(operation));

  Future<CoreSnapshot> _operate(
    CoreOperation operation, {
    bool remember = true,
  }) async {
    try {
      _operationError = null;
      if (operation == CoreOperation.validate) {
        await adapter.validate(core);
      } else {
        if (![
          CoreOperation.start,
          CoreOperation.stop,
          CoreOperation.restart,
        ].contains(operation)) {
          throw const ApiException('operation_unsupported', status: 422);
        }
        if (!supervisor.supported)
          throw const ApiException('platform_unsupported', status: 501);
        final before = await supervisor.inspect(core);
        if (!before.loaded)
          throw const ApiException('service_missing', status: 409);
        if (operation != CoreOperation.stop) await adapter.validate(core);
        if (remember)
          await _remember(
            operation == CoreOperation.stop
                ? CoreDesiredState.stopped
                : CoreDesiredState.running,
          );
        await supervisor.execute(core, operation);
        final deadline = DateTime.now().add(readyTimeout);
        while (true) {
          final service = await supervisor.inspect(core);
          if (operation == CoreOperation.stop) {
            if (service.state == CoreProcessState.inactive ||
                service.state == CoreProcessState.failed)
              break;
          } else {
            if (service.state == CoreProcessState.failed)
              throw const ApiException('service_failed');
            if (service.state == CoreProcessState.active &&
                await adapter.controllerReady(core))
              break;
          }
          if (DateTime.now().isAfter(deadline)) {
            throw ApiException(
              operation == CoreOperation.stop
                  ? 'service_stop_timeout'
                  : 'controller_not_ready',
              status: 504,
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      }
      event(operation.name);
      return await snapshot();
    } on ApiException catch (e) {
      _operationError = e.error;
      event(e.code, level: 'error');
      rethrow;
    } on Object {
      _operationError = const ApiError('internal_error');
      event('internal_error', level: 'error');
      throw const ApiException('internal_error', status: 500);
    }
  }

  void event(String code, {String level = 'info'}) => _event(level, code);

  void _event(String level, String message) {
    _events.add(
      CoreLogEntry(
        time: DateTime.now().toUtc(),
        level: level,
        message: message,
        source: 'panel',
      ),
    );
    if (_events.length > 200) _events.removeAt(0);
  }

  List<CoreLogEntry> logs() {
    final entries = [...adapter.logs, ..._events]
      ..sort((a, b) => a.time.compareTo(b.time));
    return entries
        .skip(entries.length > 200 ? entries.length - 200 : 0)
        .toList();
  }

  Future<void> clearLogs() => exclusive((_) async {
    adapter.clearLogs();
    _events.clear();
  });
}

// A capability scoped to one queued operation; it cannot escape the lock.
class CoreControl {
  CoreControl._(this._manager);
  final CoreManager _manager;
  bool _active = true;
  void _check() {
    if (!_active) throw StateError('Expired core control scope.');
  }

  Future<CoreSnapshot> execute(
    CoreOperation operation, {
    bool remember = true,
  }) {
    _check();
    return _manager._operate(operation, remember: remember);
  }

  Future<void> validateCandidate(String path) {
    _check();
    return _manager.adapter.validate(_manager.core.withConfiguration(path));
  }
}
