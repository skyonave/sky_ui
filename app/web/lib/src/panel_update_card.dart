import 'package:jaspr/jaspr.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'i18n.dart';
import 'ui.dart';

class PanelUpdateCard extends StatelessComponent {
  const PanelUpdateCard({
    required this.info,
    required this.onCheck,
    required this.onUpdate,
    this.onDetails,
    this.job,
    this.checking = false,
    this.updating = false,
    this.reconnecting = false,
    this.busy = false,
    this.updateEnabled = false,
    this.checkedManually = false,
    this.checkError,
    this.updateError,
    super.key,
  });
  final PanelUpdateInfo? info;
  final MaintenanceJob? job;
  final void Function() onCheck, onUpdate;
  final void Function()? onDetails;
  final bool checking,
      updating,
      reconnecting,
      busy,
      updateEnabled,
      checkedManually;
  final String? checkError, updateError;
  static const t = AppStrings();

  @override
  Component build(BuildContext context) {
    final progress = job?.progress;
    final failed =
        job?.status == 'failed' || checkError != null || updateError != null;
    final complete = job?.status == 'completed';
    final available = info?.available == true && checkError == null;
    final current = info?.currentVersion ?? progress?.currentVersion ?? '—';
    final target = updating
        ? progress?.targetVersion ?? info?.latestVersion
        : info?.latestVersion ?? (failed ? progress?.targetVersion : null);
    final status = checking
        ? 'checking'
        : updating
        ? reconnecting
              ? 'reconnecting'
              : 'running'
        : failed
        ? 'failed'
        : available
        ? 'available'
        : complete
        ? 'completed'
        : 'current';
    final stage = checking
        ? 'discovery'
        : progress?.failedStage ?? progress?.stage;
    final checked = DateTime.tryParse(info?.checkedAt ?? '')?.toLocal();
    final checkedTime = checked == null
        ? '—'
        : '${checked.hour.toString().padLeft(2, '0')}:${checked.minute.toString().padLeft(2, '0')}:${checked.second.toString().padLeft(2, '0')}';
    final received = progress?.bytesReceived, total = progress?.bytesTotal;
    final percent = received != null && total != null && total > 0
        ? (received / total * 100).clamp(0, 100).round()
        : null;
    final started = DateTime.tryParse(progress?.startedAt ?? '');
    final finished = DateTime.tryParse(progress?.finishedAt ?? '');
    final elapsed = started == null
        ? null
        : ((finished ?? DateTime.now()).difference(started).inSeconds).clamp(
            0,
            86400,
          );
    return div(
      [
        div([
          div([icon('down'), txt('Sky UI')], classes: 'update-heading'),
          txt(
            t('panelUpdate.state.$status'),
            classes: 'update-chip ${failed ? 'failed' : ''}',
          ),
        ], classes: 'update-header'),
        div([
          div([
            txt(t('panelUpdate.installed'), classes: 'muted'),
            txt(current, classes: 'mono'),
          ], classes: 'update-version'),
          div([
            txt(t('panelUpdate.release'), classes: 'muted'),
            txt(target ?? '—', classes: 'mono'),
          ], classes: 'update-version'),
        ], classes: 'update-versions'),
        div([
          txt(
            stage == null
                ? (job == null ? t('panelUpdate.checked') : '—')
                : t('panelUpdate.stage.$stage'),
          ),
          txt(
            elapsed == null ? (job == null ? checkedTime : '—') : '$elapsed s',
            classes: 'muted mono',
          ),
        ], classes: 'update-stage'),
        div(
          [
            div(
              [],
              classes: 'update-progress-fill ${failed ? 'failed' : ''}',
              attributes: {'style': 'width: ${percent ?? 0}%'},
            ),
          ],
          classes: 'update-progress',
          attributes: {
            if (total != null) 'role': 'progressbar',
            if (total == null) 'aria-hidden': 'true',
            'aria-label': t('panelUpdate.downloadProgress'),
            'aria-valuemin': '0',
            'aria-valuemax': '100',
            if (percent != null) 'aria-valuenow': '$percent',
          },
        ),
        div([
          if (total != null && total > 0)
            txt(
              '${((received ?? 0) / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB',
              classes: 'muted mono',
            )
          else
            a(
              [icon('github'), txt('GitHub')],
              href:
                  info?.releaseUrl ??
                  'https://github.com/skyonave/sky_ui/releases',
              target: Target.blank,
              attributes: {'rel': 'noopener noreferrer'},
              classes: 'update-source muted',
            ),
          txt(percent == null ? '' : '$percent%', classes: 'muted mono'),
        ], classes: 'update-metrics'),
        div([
          action(
            t(
              updating
                  ? 'panelUpdate.state.running'
                  : checking
                  ? 'panelUpdate.checkingAction'
                  : available
                  ? 'panelUpdate.update'
                  : 'panelUpdate.check',
            ),
            available ? onUpdate : onCheck,
            glyph: available ? 'down' : 'refresh',
            classes: 'button ${available ? 'primary' : ''}',
            disabled:
                checking ||
                updating ||
                busy ||
                (available ? !updateEnabled : info?.supported == false),
          ),
          iconButton(
            'logs',
            t('panelUpdate.details'),
            onDetails ?? () {},
            disabled: onDetails == null || (job == null && checkError == null),
          ),
        ], classes: 'update-actions'),
      ],
      classes: 'sidebar-update',
      attributes: {'aria-label': t('panelUpdate.title')},
    );
  }
}

class PanelUpdateDetails extends StatelessComponent {
  const PanelUpdateDetails({this.job, this.info, this.checkError, super.key});
  final MaintenanceJob? job;
  final PanelUpdateInfo? info;
  final String? checkError;
  static const t = AppStrings();
  @override
  Component build(BuildContext context) {
    final p = job?.progress;
    final coreJob = ['install', 'update', 'remove'].contains(job?.action);
    final values = <String, String>{
      'panelUpdate.sourceVersion':
          p?.currentVersion ?? info?.currentVersion ?? '—',
      'panelUpdate.targetVersion':
          p?.targetVersion ?? info?.latestVersion ?? '—',
      'panelUpdate.result': t(
        'panelUpdate.state.${job?.status ?? (checkError != null ? 'failed' : 'current')}',
      ),
      'panelUpdate.stageLabel': p == null
          ? '—'
          : t(
              '${coreJob ? 'coreProgress' : 'panelUpdate'}.stage.${p.failedStage ?? p.stage}',
            ),
      'panelUpdate.rollback': p?.rolledBack == null
          ? '—'
          : t(
              p!.rolledBack!
                  ? 'panelUpdate.restored'
                  : 'panelUpdate.notRestored',
            ),
      'panelUpdate.code': p?.errorCode ?? job?.error ?? checkError ?? '—',
      'panelUpdate.command': p?.command ?? '—',
      'panelUpdate.exitCode': p?.exitCode?.toString() ?? '—',
      'panelUpdate.job': job?.id ?? '—',
      'panelUpdate.started': localTime(p?.startedAt),
      'panelUpdate.finished': localTime(p?.finishedAt),
      'panelUpdate.artifact': p?.artifact ?? '—',
    };
    return el('dl', [
      for (final e in values.entries)
        div([
          el('dt', [Component.text(t(e.key))], classes: 'muted'),
          el('dd', [Component.text(e.value)], classes: 'mono'),
        ], classes: 'update-detail-row'),
    ], classes: 'update-details');
  }

  String localTime(String? value) =>
      DateTime.tryParse(value ?? '')?.toLocal().toString().substring(0, 19) ??
      '—';
}
