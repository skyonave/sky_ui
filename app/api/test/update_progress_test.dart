import 'package:test/test.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

void main() {
  test('old job receipts remain readable without progress', () {
    final job = MaintenanceJob.fromJson({
      'id': 'a',
      'action': 'panel-update',
      'status': 'failed',
      'error': 'panel_update_rolled_back',
    });
    expect(job.progress, isNull);
    expect(job.toJson().containsKey('progress'), isFalse);
  });
  test('update telemetry survives the server/browser contract', () {
    final job = MaintenanceJob.fromJson({
      'id': 'a',
      'action': 'panel-update',
      'status': 'failed',
      'progress': {
        'stage': 'rollback',
        'currentVersion': '0.6.0-dev.4',
        'targetVersion': '0.7.0-dev.2',
        'failedStage': 'prepare',
        'bytesReceived': 2048,
        'bytesTotal': 4096,
        'exitCode': 23,
        'rolledBack': true,
        'errorCode': 'installer_failed',
        'startedAt': '2026-11-02T00:00:00Z',
      },
    });
    final copy = MaintenanceJob.fromJson(job.toJson());
    expect(copy.progress!.failedStage, 'prepare');
    expect(copy.progress!.exitCode, 23);
    expect(copy.progress!.rolledBack, isTrue);
    expect(copy.progress!.bytesReceived, 2048);
  });
}
