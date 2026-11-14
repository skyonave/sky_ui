import 'dart:io';

import 'check_architecture.dart' as architecture;

Future<void> main(List<String> args) async {
  final root = File(Platform.script.toFilePath()).parent.parent.path;
  final violations = architecture.checkArchitecture(Directory(root));
  if (violations.isNotEmpty) {
    stderr.writeln(violations.join('\n'));
    exitCode = 1;
    return;
  }
  final guardTest = await Process.run(Platform.resolvedExecutable, [
    '$root/tool/architecture_check_test.dart',
  ]);
  if (guardTest.exitCode != 0) {
    stderr.write(guardTest.stderr);
    exitCode = guardTest.exitCode;
    return;
  }
  for (final package in ['api', 'ops']) {
    for (final arguments in [
      ['analyze'],
      ['test', '--concurrency=1'],
    ]) {
      final process = await Process.start(
        Platform.resolvedExecutable,
        arguments,
        workingDirectory: '$root/app/$package',
        mode: ProcessStartMode.inheritStdio,
      );
      final result = await process.exitCode;
      if (result != 0) {
        exitCode = result;
        return;
      }
    }
  }
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['analyze', 'lib', 'web', 'tool'],
    workingDirectory: '$root/app/web',
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await process.exitCode;
  if (exitCode != 0) return;
  for (final check in [
    'connection_draft_check.dart',
    'routing_order_check.dart',
    'localization_check.dart',
  ]) {
    final process = await Process.start(
      Platform.resolvedExecutable,
      ['run', 'tool/$check'],
      workingDirectory: '$root/app/web',
      mode: ProcessStartMode.inheritStdio,
    );
    exitCode = await process.exitCode;
    if (exitCode != 0) return;
  }
}
