import 'dart:io';

import '../features/maintenance/worker.dart';
import '../platform/host.dart';

Future<void> interactive(List<String> args, {bool check = true}) async {
  final p = await Process.start(
    args.first,
    args.skip(1).toList(),
    mode: ProcessStartMode.inheritStdio,
    environment: cleanEnvironment,
    includeParentEnvironment: false,
  );
  final code = await p.exitCode;
  require(!check || code == 0, 'command_failed');
}

String prompt(String question) {
  stdout.write(question);
  return stdin.readLineSync() ?? '';
}

void managed() {
  require(host.uid() == 0, 'root_required');
  host.trusted('$etc/managed-by-sky-ui');
}

Future<T> locked<T>(Future<T> Function() work) async {
  await waitCleanup();
  require(!exists('$state/panel-update-intent.json'), 'maintenance_busy');
  final install = HostLock('/run/lock/sky-ui-install.lock'),
      worker = HostLock('$state/worker.lock');
  try {
    await install.acquire();
    await worker.acquire();
    return await work();
  } finally {
    worker.close();
    install.close();
  }
}
