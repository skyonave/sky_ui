import 'dart:io';

Future<void> main(List<String> args) async {
  final root = File(Platform.script.toFilePath()).parent.parent.path;
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['run', 'tool/generate_mihomo_schema.dart', ...args],
    workingDirectory: '$root/app/ops',
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await process.exitCode;
}
