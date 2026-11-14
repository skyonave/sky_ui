import 'dart:async';
import 'dart:io';
import 'package:sky_ui_api/src/infrastructure/process/command_runner.dart';
import 'package:sky_ui_api/src/shared/api_exception.dart';
import 'package:test/test.dart';

void main() {
  test(
    'cancellation terminates the owned process before its command timeout',
    () async {
      // Some Windows app-container temp paths contain '#', which the Dart
      // source launcher parses as a URI fragment. Keep this SDK fixture local.
      final dir = await Directory('.dart_tool').createTemp('command-cancel-');
      final cancel = Completer<void>();
      Future<void>? observed;
      try {
        final script = File('${dir.path}/wait.dart');
        final ready = File('${dir.path}/ready');
        await script.writeAsString(
          "import 'dart:io'; Future<void> main(List<String> args) async { File(args.single).writeAsStringSync('ready'); await Future<void>.delayed(const Duration(minutes: 2)); }",
        );
        // dart test may run in dartvm, which cannot compile a source file.
        final dart = File(
          '${File(Platform.resolvedExecutable).parent.path}/dart${Platform.isWindows ? '.exe' : ''}',
        );
        expect(
          dart.existsSync(),
          isTrue,
          reason: 'The SDK frontend must be next to the VM.',
        );
        final command = const NativeCommandRunner().runWithInput(
          dart.path,
          [script.path, ready.path],
          timeout: const Duration(seconds: 30),
          cancellation: cancel.future,
        );
        CommandResult? earlyResult;
        Object? failure;
        var completed = false;
        observed = command.then<void>(
          (value) {
            earlyResult = value;
            completed = true;
          },
          onError: (Object error, StackTrace _) {
            failure = error;
            completed = true;
          },
        );
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!ready.existsSync() &&
            !completed &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          ready.existsSync(),
          isTrue,
          reason:
              'Fixture exited before readiness: exit=${earlyResult?.exitCode}, output=${earlyResult?.output}, error=$failure',
        );
        final watch = Stopwatch()..start();
        cancel.complete();
        await observed;
        expect(
          failure,
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'command_cancelled',
          ),
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      } finally {
        if (!cancel.isCompleted) cancel.complete();
        await observed;
        await dir.delete(recursive: true);
      }
    },
  );
}
