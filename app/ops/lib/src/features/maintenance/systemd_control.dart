import 'dart:io';

import '../../platform/host.dart';

List<String>? systemdControlCommand(String request) {
  final fields = request.split(' ');
  if (fields.length != 2) return null;
  final [verb, unit] = fields;
  const workers = {'sky-ui-maintenance.service', 'sky-ui-update.service'};
  if (workers.contains(unit)) {
    return verb == 'start'
        ? ['/usr/bin/systemctl', 'start', '--no-block', unit]
        : null;
  }
  if (engineIds.any((engine) => unit == 'sky-ui-$engine.service') &&
      const {'start', 'stop', 'restart', 'reset-failed'}.contains(verb)) {
    return ['/usr/bin/systemctl', '--no-ask-password', verb, unit];
  }
  return null;
}

Future<void> handleSystemdControl() async {
  final bytes = <int>[];
  for (var i = 0; i < 64; i++) {
    final byte = stdin.readByteSync();
    if (byte == 10) {
      final args = systemdControlCommand(String.fromCharCodes(bytes));
      if (args != null) {
        final result = await command(
          args,
          check: false,
          timeout: const Duration(seconds: 14),
        );
        if (result.exitCode != 0) stderr.write(result.stderr);
        stdout.write(result.exitCode == 0 ? '0' : '1');
        await stdout.flush();
        return;
      }
      break;
    }
    if (byte < 32 || byte > 126) break;
    bytes.add(byte);
  }
  stdout.write('1');
  await stdout.flush();
}
