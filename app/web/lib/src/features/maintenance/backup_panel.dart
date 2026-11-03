import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';

class BackupPanel extends StatelessComponent {
  const BackupPanel({
    required this.maintenance,
    required this.maintenanceBusy,
    required this.maintenanceLoading,
    required this.appVersion,
    required this.maintenanceStatus,
    required this.onCreate,
    required this.onRestore,
    super.key,
  });
  final MaintenanceSnapshot? maintenance;
  final bool maintenanceBusy;
  final bool maintenanceLoading;
  final String appVersion;
  final Component Function() maintenanceStatus;
  final void Function() onCreate;
  final void Function(String) onRestore;
  final t = const AppStrings();
  @override
  Component build(BuildContext context) => div([
    div([
      h2([Component.text(t('maintenance.backups'))]),
      action(
        t('maintenance.create'),
        onCreate,
        glyph: 'plus',
        disabled: maintenance?.available != true || maintenanceBusy,
      ),
    ], classes: 'maintenance-heading'),
    maintenanceStatus(),
    if (maintenance?.available != true) pill(t('feature.unavailable')),
    if (maintenance?.available == true && maintenance!.backups.isEmpty)
      p([Component.text(t('maintenance.empty'))], classes: 'muted small'),
    for (final backup in maintenance?.backups ?? <BackupInfo>[])
      div([
        div([
          txt(
            DateTime.tryParse(
                  backup.created,
                )?.toLocal().toString().substring(0, 19) ??
                backup.created,
          ),
          txt(
            'Sky UI ${backup.version} · ${backup.size < 1000000 ? '${(backup.size / 1000).toStringAsFixed(1)} KB' : '${(backup.size / 1000000).toStringAsFixed(1)} MB'}',
            classes: 'muted small',
          ),
        ]),
        div([
          a(
            [Component.text(t('maintenance.download'))],
            href: '/api/v1/backups/${backup.id}/download',
            classes: 'button',
            attributes: {'download': 'sky-ui-${backup.id}.tar.gz'},
          ),
          action(t('maintenance.restore'), () {
            onRestore(backup.id);
          }, disabled: maintenanceBusy || backup.version != appVersion),
        ], classes: 'core-actions'),
      ], classes: 'setting-row'),
    p([Component.text(t('maintenance.secrets'))], classes: 'muted small'),
  ], classes: 'panel settings-panel');
}
