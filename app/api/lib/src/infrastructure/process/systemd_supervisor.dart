import 'dart:io';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../engines/contracts.dart';
import '../../engines/managed_core.dart';
import '../../shared/api_exception.dart';
import 'command_runner.dart';
import 'systemd_control.dart';

class SystemdSupervisor implements ProcessSupervisor {
  SystemdSupervisor(this.runner, {this.control, bool? linux})
    : supported = linux ?? Platform.isLinux;
  final CommandRunner runner;
  final SystemdControl? control;
  @override
  final bool supported;

  void _check(ManagedCore core) {
    if (!supported)
      throw const ApiException('platform_unsupported', status: 501);
    if (!RegExp(r'^sky-ui-[a-z0-9-]+\.service$').hasMatch(core.service)) {
      throw const ApiException('service_not_owned', status: 409);
    }
  }

  @override
  Future<ServiceObservation> inspect(ManagedCore core) async {
    if (!supported)
      return const ServiceObservation(
        CoreProcessState.unavailable,
        loaded: false,
        error: ApiError('platform_unsupported'),
      );
    _check(core);
    final result = await runner.run('/usr/bin/systemctl', [
      'show',
      '--no-pager',
      '--property=LoadState,ActiveState,MemoryCurrent,ExecMainStatus,MainPID',
      core.service,
    ]);
    final properties = <String, String>{};
    for (final line in result.output.split('\n')) {
      final separator = line.indexOf('=');
      if (separator > 0)
        properties[line.substring(0, separator)] = line
            .substring(separator + 1)
            .trim();
    }
    if (properties['LoadState'] == 'not-found') {
      return const ServiceObservation(
        CoreProcessState.unavailable,
        loaded: false,
        error: ApiError('service_missing'),
      );
    }
    if (result.exitCode != 0 || properties['LoadState'] != 'loaded') {
      throw const ApiException('supervisor_unavailable');
    }
    final state =
        CoreProcessState.values
            .where((v) => v.name == properties['ActiveState'])
            .firstOrNull ??
        CoreProcessState.unknown;
    return ServiceObservation(
      state,
      processId: int.tryParse(properties['MainPID'] ?? ''),
      memoryBytes: int.tryParse(properties['MemoryCurrent'] ?? ''),
      error: state == CoreProcessState.failed
          ? const ApiError('service_failed')
          : null,
    );
  }

  @override
  Future<void> execute(ManagedCore core, CoreOperation operation) async {
    _check(core);
    if (![
      CoreOperation.start,
      CoreOperation.stop,
      CoreOperation.restart,
    ].contains(operation)) {
      throw const ApiException('operation_unsupported', status: 422);
    }
    final observed = await inspect(core);
    if (!observed.loaded)
      throw const ApiException('service_missing', status: 409);
    if (operation != CoreOperation.stop) {
      // Explicit owner actions may be frequent; retain crash-loop limits for automatic restarts.
      final reset = await _execute('reset-failed', core.service);
      // systemd may garbage-collect a stopped, never-used unit between inspect
      // and reset-failed. Starting it remains valid; a failed unit must reset.
      if (reset.exitCode != 0 && observed.state == CoreProcessState.failed)
        throw const ApiException('service_operation_failed');
    }
    final result = await _execute(operation.name, core.service);
    if (result.exitCode != 0)
      throw const ApiException('service_operation_failed');
  }

  Future<CommandResult> _execute(String verb, String unit) =>
      control?.run(verb, unit) ??
      runner.run('/usr/bin/systemctl', ['--no-ask-password', verb, unit]);
}
