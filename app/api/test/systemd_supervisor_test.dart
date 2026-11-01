import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';
import 'core_manager_test.dart' show fixtureCore;

class CollectedUnitRunner implements CommandRunner {
  bool failed = false;
  bool started = false;
  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (arguments.contains('show'))
      return CommandResult(
        0,
        'LoadState=loaded\nActiveState=${failed ? 'failed' : 'inactive'}\nMainPID=0\n',
      );
    if (arguments.contains('reset-failed'))
      return const CommandResult(1, 'Unit not loaded');
    if (arguments.contains('start')) started = true;
    return const CommandResult(0, '');
  }
}

void main() {
  test('a stopped garbage-collected systemd unit can still start', () async {
    final runner = CollectedUnitRunner();
    await SystemdSupervisor(
      runner,
      linux: true,
    ).execute(fixtureCore(), CoreOperation.start);
    expect(runner.started, true);
  });
  test('a failed unit still requires a successful crash-loop reset', () async {
    final runner = CollectedUnitRunner()..failed = true;
    await expectLater(
      SystemdSupervisor(
        runner,
        linux: true,
      ).execute(fixtureCore(), CoreOperation.start),
      throwsA(isA<ApiException>()),
    );
    expect(runner.started, false);
  });
}
