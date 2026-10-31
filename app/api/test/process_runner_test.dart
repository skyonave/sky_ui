import 'dart:io';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:test/test.dart';

void main() {
  const runner = NativeCommandRunner();
  final dart = Platform.resolvedExecutable;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sky-ui-process-');
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  test('drains noisy output while bounding retained bytes', () async {
    final script = File('${directory.path}/noisy.dart');
    await script.writeAsString(
      "import 'dart:io'; void main() { stdout.write('x' * 100000); stderr.write('y' * 100000); }",
    );
    final result = await runner.run(dart, [script.path]);
    expect(result.exitCode, 0, reason: result.output);
    expect(result.output.length, 16384);
  });
  test('hung commands time out and are terminated', () async {
    final script = File('${directory.path}/hung.dart');
    await script.writeAsString(
      "import 'dart:async'; void main() { Timer.periodic(const Duration(seconds:1), (_) {}); }",
    );
    await expectLater(
      runner.run(dart, [
        script.path,
      ], timeout: const Duration(milliseconds: 500)),
      throwsA(
        isA<ApiException>().having((v) => v.code, 'code', 'command_timeout'),
      ),
    );
  });
  test('configured secrets and common credentials are redacted', () {
    final text = redact(
      'Bearer abc password=hunter2 secret=s3cr3t token=tok https://bob:pw@example.com id=private-value',
      ['private-value'],
    );
    expect(text, isNot(contains('hunter2')));
    expect(text, isNot(contains('s3cr3t')));
    expect(text, isNot(contains('tok ')));
    expect(text, isNot(contains('bob:pw')));
    expect(text, isNot(contains('private-value')));
  });
}
