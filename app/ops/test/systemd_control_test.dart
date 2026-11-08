import 'package:sky_ui_ops/src/features/maintenance/systemd_control.dart';
import 'package:sky_ui_ops/src/platform/host.dart';
import 'package:test/test.dart';

void main() {
  test('the socket exposes only the managed lifecycle operations', () {
    for (final engine in engineIds) {
      final unit = 'sky-ui-$engine.service';
      for (final verb in ['start', 'stop', 'restart', 'reset-failed']) {
        expect(systemdControlCommand('$verb $unit'), [
          '/usr/bin/systemctl',
          '--no-ask-password',
          verb,
          unit,
        ]);
      }
    }
    for (final unit in [
      'sky-ui-maintenance.service',
      'sky-ui-update.service',
    ]) {
      expect(systemdControlCommand('start $unit'), [
        '/usr/bin/systemctl',
        'start',
        '--no-block',
        unit,
      ]);
      expect(systemdControlCommand('restart $unit'), isNull);
    }
  });

  test('requests cannot target other services or pass systemctl arguments', () {
    for (final request in [
      'start ssh.service',
      'start sky-ui.service',
      'start sky-ui-unmanaged.service',
      'start sky-ui-amneziawg@other.service',
      'enable sky-ui-amneziawg.service',
      'start --no-block sky-ui-amneziawg.service',
      'start sky-ui-amneziawg.service ssh.service',
      'start sky-ui-amneziawg.service\nstop ssh.service',
    ]) {
      expect(systemdControlCommand(request), isNull, reason: request);
    }
  });
}
