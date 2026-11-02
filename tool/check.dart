import 'dart:io';

Future<void> main(List<String> args) async {
  final root = File(Platform.script.toFilePath()).parent.parent.path;
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
}
