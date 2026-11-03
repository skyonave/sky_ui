import 'dart:io';

Future<void> main(List<String> args) async {
  final root = File(Platform.script.toFilePath()).parent.parent.path;
  final forwarded = args
      .map(
        (arg) => ['--check', '--check-amd64', '--check-arm64'].contains(arg)
            ? arg
            : File(arg).absolute.path,
      )
      .toList();
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['run', 'tool/draft_release.dart', ...forwarded],
    workingDirectory: '$root/app/ops',
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await process.exitCode;
}
