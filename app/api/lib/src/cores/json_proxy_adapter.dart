import 'dart:convert';
import 'dart:io';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import '../config.dart';
import '../errors.dart';
import '../process_runner.dart';
import 'contracts.dart';

/// Only the required lifecycle/validation interface; no fictitious controller API.
class JsonProxyAdapter implements CoreAdapter {
  JsonProxyAdapter(this.id, this.runner, this.supervisor);
  @override
  final String id;
  final CommandRunner runner;
  final ProcessSupervisor supervisor;
  final _logs = <CoreLogEntry>[];
  DateTime? _since;
  DateTime? _clearedAt;
  final _seen = <String>{};
  bool _observing = false;
  @override
  String get name => id == 'xray' ? 'Xray' : 'sing-box';
  @override
  Future<BinaryProbe> probe(ManagedCore core) async {
    if (!await File(core.binary).exists())
      return const BinaryProbe(false, null);
    final result = await runner.run(core.binary, [
      'version',
    ], timeout: const Duration(seconds: 3));
    final version = RegExp(
      r'\bv?\d+\.\d+\.\d+[^\s]*',
    ).firstMatch(result.output)?.group(0);
    if (result.exitCode != 0 || version == null)
      throw const ApiException('binary_probe_failed');
    return BinaryProbe(true, version);
  }

  @override
  Future<void> validate(ManagedCore core) async {
    if (!await File(core.binary).exists())
      throw const ApiException('binary_missing', status: 409);
    if (!await File(core.configuration).exists())
      throw const ApiException('configuration_missing', status: 409);
    final result = await runner.run(
      core.binary,
      id == 'xray'
          ? ['run', '-test', '-config', core.configuration]
          : ['check', '-c', core.configuration],
    );
    if (result.exitCode != 0)
      throw const ApiException('configuration_invalid', status: 422);
  }

  @override
  Future<bool> controllerReady(ManagedCore core) async {
    // These engines do not need a control port. Codec verification checks listeners.
    final process = await supervisor.inspect(core);
    return process.loaded && process.state == CoreProcessState.active;
  }

  @override
  List<CoreLogEntry> get logs => List.unmodifiable(_logs);
  @override
  void clearLogs() {
    _logs.clear();
    _since = DateTime.now().toUtc();
    _clearedAt = _since;
    _seen.clear();
  }

  @override
  Future<void> observeLogs(ManagedCore core) async {
    if (!Platform.isLinux || _observing) return;
    _observing = true;
    try {
      final result = await runner.run('/usr/bin/journalctl', [
        '--unit',
        core.service,
        '--no-pager',
        '--output=json',
        '--lines=100',
        if (_since != null) '--since=@${_since!.millisecondsSinceEpoch / 1000}',
      ]);
      if (result.exitCode != 0) return;
      for (final line in result.output.split('\n').where((l) => l.isNotEmpty)) {
        try {
          final value = jsonDecode(line) as Map;
          final time = DateTime.fromMicrosecondsSinceEpoch(
            int.parse(value['__REALTIME_TIMESTAMP'] as String),
            isUtc: true,
          );
          if (_clearedAt != null && !time.isAfter(_clearedAt!)) continue;
          final cursor =
              value['__CURSOR'] as String? ??
              '${time.microsecondsSinceEpoch}:${value['MESSAGE']}';
          if (!_seen.add(cursor)) continue;
          final message = redact(
            (value['MESSAGE'] as String? ?? '').replaceAll(
              RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'),
              '',
            ),
            [core.secret],
          );
          _logs.add(
            CoreLogEntry(
              time: time,
              level: logLevel(message, value['PRIORITY']?.toString()),
              message: message,
              source: id,
            ),
          );
          if (_since == null || time.isAfter(_since!)) _since = time;
        } on Object {
          continue;
        }
      }
      if (_logs.length > 200) _logs.removeRange(0, _logs.length - 200);
      while (_seen.length > 400) {
        _seen.remove(_seen.first);
      }
    } finally {
      _observing = false;
    }
  }

  static String logLevel(String message, [String? priority]) {
    final explicit = RegExp(
      r'\b(debug|info|warning|warn|error|fatal|panic)\b',
      caseSensitive: false,
    ).firstMatch(message)?.group(1)?.toLowerCase();
    if (explicit != null)
      return switch (explicit) {
        'warn' => 'warning',
        'panic' => 'fatal',
        _ => explicit,
      };
    return switch (priority) {
      '0' || '1' || '2' => 'fatal',
      '3' => 'error',
      '4' => 'warning',
      '7' => 'debug',
      _ => 'info',
    };
  }

  @override
  Future<void> close() async {}
}
