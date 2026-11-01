import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:sky_ui_web/src/core_install_progress.dart';

/// Render the real progress component without any credentials or engine jobs.
void main() {
  final scenario = Uri.base.queryParameters['state'] ?? 'download';
  final failed = scenario == 'failed';
  final complete = scenario == 'complete';
  final stage = failed ? 'build' : scenario;
  final job = MaintenanceJob.fromJson({
    'id': 'fixture',
    'core': 'amneziawg',
    'tag': 'v3.1.20260828',
    'action': 'install',
    'status': failed
        ? 'failed'
        : complete
        ? 'completed'
        : 'running',
    if (failed) 'error': 'core_build_failed',
    'progress': {
      'stage': stage,
      'startedAt': DateTime.now()
          .toUtc()
          .subtract(const Duration(seconds: 42))
          .toIso8601String(),
      if (complete || failed)
        'finishedAt': DateTime.now().toUtc().toIso8601String(),
      if (stage == 'download' || stage == 'toolchain') ...{
        'bytesReceived': 16777216,
        'bytesTotal': 67108864,
        'artifact': stage == 'toolchain'
            ? 'go1.27.3.linux-amd64.tar.gz'
            : 'amneziawg-go.tar.gz',
      },
      if (stage == 'build') 'command': 'go build',
      if (failed) ...{
        'failedStage': 'build',
        'exitCode': 17,
        'errorCode': 'core_build_failed',
      },
    },
  });
  runApp(
    div([
      div(
        [
          div([
            h2([Component.text('Новое подключение')]),
          ], classes: 'modal-header'),
          div([
            p([Component.text('AmneziaWG')]),
            CoreInstallProgress(
              core: 'amneziawg',
              job: job,
              busy: !failed && !complete,
            ),
          ], classes: 'modal-body'),
          div([
            button([Component.text('Отмена')], classes: 'button secondary'),
          ], classes: 'modal-footer'),
        ],
        classes: 'modal wide',
        attributes: {'role': 'dialog'},
      ),
    ], classes: 'modal-overlay'),
    attachTo: '#app',
  );
}
