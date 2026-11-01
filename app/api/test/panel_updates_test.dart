import 'dart:convert';
import 'package:sky_ui_api/src/panel_updates.dart';
import 'package:sky_ui_api/src/process_runner.dart';
import 'package:sky_ui_api/src/errors.dart';
import 'package:test/test.dart';

class ReleaseRunner implements CommandRunner {
  final calls = <List<String>>[];
  bool approved = true;
  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    calls.add([executable, ...arguments]);
    return CommandResult(
      0,
      jsonEncode({
        'currentVersion': '0.6.0-dev.4',
        'available': approved,
        'supported': true,
        'checkedAt': '2026-11-01T00:00:00Z',
        'latestVersion': approved ? '0.6.0-dev.5' : null,
        'tag': approved ? 'v0.6.0-dev.5' : null,
        'releaseUrl': approved
            ? 'https://github.com/skyonave/sky_ui/releases/tag/v0.6.0-dev.5'
            : null,
      }),
    );
  }
}

void main() {
  test(
    'checks are cached but confirmation revalidates release availability',
    () async {
      final runner = ReleaseRunner();
      final service = PanelUpdates(
        runner,
        supported: true,
        current: '0.6.0-dev.4',
        platform: 'linux-amd64',
      );
      expect((await service.get()).available, true);
      expect((await service.get()).available, true);
      expect(runner.calls.length, 1);
      runner.approved = false;
      await expectLater(
        service.requireApproved('v0.6.0-dev.5'),
        throwsA(isA<ApiException>()),
      );
      expect(runner.calls.length, 2);
      expect(runner.calls.last, containsAllInOrder(['--tag', 'v0.6.0-dev.5']));
    },
  );
  test('unsupported installations do not invoke an update helper', () async {
    final runner = ReleaseRunner();
    final service = PanelUpdates(runner, supported: false);
    expect((await service.get()).available, false);
    expect(runner.calls, isEmpty);
  });
  test(
    'manual checks bypass the cache and replace its previous result',
    () async {
      final runner = ReleaseRunner()..approved = false;
      final service = PanelUpdates(
        runner,
        supported: true,
        current: '0.6.0-dev.4',
        platform: 'linux-amd64',
      );
      expect((await service.get()).available, false);
      runner.approved = true;
      expect((await service.get()).available, false);
      expect(runner.calls, hasLength(1));
      expect((await service.get(refresh: true)).available, true);
      expect((await service.get()).available, true);
      expect(runner.calls, hasLength(2));
    },
  );
}
