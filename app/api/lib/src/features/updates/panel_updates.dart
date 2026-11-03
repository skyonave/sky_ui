import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../bootstrap/server_config.dart';
import '../../infrastructure/process/command_runner.dart';
import '../../shared/api_exception.dart';

/// Runs the shared discovery helper without privileges; installation rechecks it as root.
class PanelUpdates {
  PanelUpdates(
    this.runner, {
    this.script = '/opt/sky-ui/current/bin/sky-ops',
    bool? supported,
    String? current,
    String? platform,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now,
       supported = supported ?? (Platform.isLinux && File(script).existsSync()),
       current = current ?? skyUiVersion,
       platform =
           platform ??
           switch (Abi.current()) {
             Abi.linuxX64 => 'linux-amd64',
             Abi.linuxArm64 => 'linux-arm64',
             _ => 'unsupported',
           };
  final CommandRunner runner;
  final String script, current, platform;
  final bool supported;
  final DateTime Function() now;
  PanelUpdateInfo? _cached;
  DateTime? _checked;
  Future<PanelUpdateInfo>? _pending;
  ApiException? _failure;

  Future<PanelUpdateInfo> get({bool refresh = false}) async {
    if (_pending != null) return _pending!;
    if (!refresh &&
        _checked != null &&
        now().difference(_checked!) < const Duration(hours: 1)) {
      if (_failure != null) throw _failure!;
      if (_cached != null) return _cached!;
    }
    _checked = now();
    return _pending = _read()
        .then(
          (value) {
            _cached = value;
            _failure = null;
            return value;
          },
          onError: (Object error) {
            _failure = error is ApiException
                ? error
                : const ApiException('release_feed_unavailable', status: 503);
            throw _failure!;
          },
        )
        .whenComplete(() => _pending = null);
  }

  Future<PanelUpdateInfo> _read({String? tag}) async {
    if (!supported)
      return PanelUpdateInfo(
        currentVersion: current,
        available: false,
        supported: false,
        checkedAt: DateTime.now().toUtc().toIso8601String(),
      );
    try {
      final result = await runner.run(script, [
        'releases',
        'check',
        '--version',
        current,
        '--platform',
        platform,
        if (tag != null) ...['--tag', tag],
      ], timeout: const Duration(seconds: 35));
      if (result.exitCode != 0) throw const FormatException();
      final value = PanelUpdateInfo.fromJson(
        jsonDecode(result.output) as Map<String, dynamic>,
      );
      if (value.currentVersion != current ||
          (value.available &&
              (value.tag == null ||
                  !RegExp(
                    r'^v[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.\-]+)?$',
                  ).hasMatch(value.tag!)))) {
        throw const FormatException();
      }
      return value;
    } on Object {
      throw const ApiException('release_feed_unavailable', status: 503);
    }
  }

  Future<void> requireApproved(String tag) async {
    final value = await _read(tag: tag);
    if (!value.available || value.tag != tag)
      throw const ApiException('panel_update_unavailable', status: 422);
  }
}
