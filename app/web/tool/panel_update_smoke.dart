import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:sky_ui_web/src/shared/api/api_client.dart';
import 'package:sky_ui_web/src/features/updates/update_card.dart';

/// Browser fixture using the production update card and HTTP client.
void main() => runApp(const UpdateSmoke(), attachTo: '#app');

class UpdateSmoke extends StatefulComponent {
  const UpdateSmoke({super.key});
  @override
  State<UpdateSmoke> createState() => _UpdateSmoke();
}

class _UpdateSmoke extends State<UpdateSmoke> {
  final api = ApiClient();
  PanelUpdateInfo info = const PanelUpdateInfo(
    currentVersion: '0.6.0-dev.4',
    available: false,
    supported: true,
    checkedAt: '2026-11-01T00:00:00Z',
  );
  bool checking = false, checked = false, confirmation = false;
  String? error;
  final scenario = Uri.base.queryParameters['state'] ?? 'idle';
  bool details = false;
  MaintenanceJob? get fixtureJob {
    if (![
      'download',
      'install',
      'reconnecting',
      'failed',
      'complete',
    ].contains(scenario))
      return null;
    return MaintenanceJob.fromJson({
      'id': 'a123456789abcdef0123456789abcdef',
      'action': 'panel-update',
      'status': scenario == 'failed'
          ? 'failed'
          : scenario == 'complete'
          ? 'completed'
          : 'running',
      if (scenario == 'failed') 'error': 'panel_update_rolled_back',
      'progress': {
        'stage': scenario == 'failed'
            ? 'rollback'
            : scenario == 'complete'
            ? 'complete'
            : scenario == 'download'
            ? 'download'
            : 'install',
        'currentVersion': '0.6.0-dev.4',
        'targetVersion': '0.7.0-dev.2',
        'startedAt': DateTime.now()
            .toUtc()
            .subtract(const Duration(seconds: 12))
            .toIso8601String(),
        if (['failed', 'complete'].contains(scenario))
          'finishedAt': DateTime.now().toUtc().toIso8601String(),
        'bytesReceived': scenario == 'download' ? 11534336 : 23068672,
        'bytesTotal': 23068672,
        if (scenario == 'failed') ...{
          'failedStage': 'prepare',
          'errorCode': 'installer_failed',
          'exitCode': 1,
          'command': 'install.sh',
          'rolledBack': true,
        },
      },
    });
  }

  Future<void> check() async {
    setState(() => checking = true);
    try {
      final result = await api.panelUpdate(refresh: true);
      setState(() {
        info = result;
        error = null;
        checked = true;
      });
    } on ApiClientException {
      setState(() => error = 'Не удалось проверить обновления');
    } finally {
      setState(() => checking = false);
    }
  }

  @override
  Component build(BuildContext context) => div(
    [
      PanelUpdateCard(
        info: scenario == 'available'
            ? const PanelUpdateInfo(
                currentVersion: '0.6.0-dev.4',
                latestVersion: '0.7.0-dev.2',
                tag: 'v0.7.0-dev.2',
                available: true,
                supported: true,
                checkedAt: '2026-11-02T00:00:00Z',
              )
            : info,
        job: fixtureJob,
        updating: fixtureJob?.busy == true,
        reconnecting: scenario == 'reconnecting',
        onDetails: () => setState(() => details = true),
        checking: checking,
        checkedManually: checked,
        checkError: error,
        updateEnabled: true,
        onCheck: check,
        onUpdate: () => setState(() => confirmation = true),
      ),
      if (details)
        div([
          div([
            div([
              h2([Component.text('Детали обновления')]),
            ], classes: 'modal-header'),
            div([
              PanelUpdateDetails(job: fixtureJob, info: info),
            ], classes: 'modal-body'),
            div([
              button([
                Component.text('Закрыть'),
              ], onClick: () => setState(() => details = false)),
            ], classes: 'modal-footer'),
          ], classes: 'modal'),
        ], classes: 'modal-overlay'),
      if (confirmation) p([Component.text('Подтверждение обновления')]),
    ],
    styles: const Styles(
      width: Unit.pixels(232),
      padding: Padding.all(Unit.pixels(12)),
    ),
  );
}
