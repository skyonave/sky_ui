import 'package:jaspr/jaspr.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'i18n.dart';
import 'panel_update_card.dart';
import 'ui.dart';

class CoreInstallProgress extends StatelessComponent {
  const CoreInstallProgress({
    required this.core,
    this.job,
    this.busy = false,
    this.reconnecting = false,
    super.key,
  });
  final String core;
  final MaintenanceJob? job;
  final bool busy, reconnecting;
  static const t = AppStrings();
  @override
  Component build(BuildContext context) {
    final p = job?.progress;
    final failed = job?.status == 'failed',
        complete = job?.status == 'completed';
    final stage = p?.failedStage ?? p?.stage ?? 'discovery';
    final steps = [
      'download',
      if (core == 'amneziawg') ...'toolchain build'.split(' '),
      'validate',
      'activate',
    ];
    final position = stage == 'complete' || stage == 'health'
        ? steps.length
        : steps.indexOf(stage);
    final total = p?.bytesTotal, received = p?.bytesReceived;
    final percent = complete
        ? 100
        : total != null && total > 0 && received != null
        ? (received / total * 100).clamp(0, 100).round()
        : null;
    final started = DateTime.tryParse(p?.startedAt ?? '');
    final finished = DateTime.tryParse(p?.finishedAt ?? '');
    final elapsed = started == null
        ? null
        : (finished ?? DateTime.now())
              .difference(started)
              .inSeconds
              .clamp(0, 86400);
    return div(
      [
        div([
          txt(t('coreProgress.stage.$stage')),
          txt(
            t(
              reconnecting
                  ? 'builder.reconnecting'
                  : failed
                  ? 'panelUpdate.state.failed'
                  : complete
                  ? 'panelUpdate.state.completed'
                  : 'coreProgress.state.running',
            ),
            classes: 'protocol-tag',
          ),
        ], classes: 'core-install-heading'),
        div([
          for (final step in steps)
            div(
              [
                icon(position > steps.indexOf(step) ? 'check' : 'down'),
                txt(t('coreProgress.step.$step')),
              ],
              classes:
                  'core-install-step ${step == stage
                      ? 'active'
                      : position > steps.indexOf(step)
                      ? 'done'
                      : ''}',
            ),
        ], classes: 'core-install-steps'),
        div(
          [
            div(
              [],
              classes:
                  'core-install-fill ${busy && percent == null ? 'indeterminate' : ''}',
              attributes: {'style': 'width: ${percent ?? 0}%'},
            ),
          ],
          classes: 'core-install-bar',
          attributes: {
            'role': 'progressbar',
            'aria-label': t('builder.installing'),
            if (percent != null) 'aria-valuenow': '$percent',
            'aria-valuemin': '0',
            'aria-valuemax': '100',
          },
        ),
        div([
          txt(
            received == null
                ? p?.command ?? '—'
                : total == null
                ? '${(received / 1048576).toStringAsFixed(1)} MB'
                : '${(received / 1048576).toStringAsFixed(1)} / ${(total / 1048576).toStringAsFixed(1)} MB',
            classes: 'mono muted',
          ),
          txt(
            '${percent == null ? '' : '$percent% · '}${elapsed == null ? '—' : '$elapsed s'}',
            classes: 'mono muted',
          ),
        ], classes: 'core-install-heading'),
        div([
          txt(
            p?.artifact ?? (stage == 'build' ? 'Go build' : job?.tag ?? '—'),
            classes: 'muted mono',
          ),
        ], classes: 'core-install-artifact'),
        if (failed)
          div([
            txt(
              '${p?.errorCode ?? job?.error ?? 'maintenance_failed'}${p?.exitCode == null ? '' : ' · exit ${p!.exitCode}'}',
              classes: 'mono',
            ),
          ], classes: 'form-error'),
        if (job != null)
          el('details', [
            el('summary', [Component.text(t('builder.installDetails'))]),
            PanelUpdateDetails(job: job),
          ], classes: 'core-install-details'),
      ],
      classes: 'core-install-progress',
      attributes: {'aria-label': t('builder.installing')},
    );
  }
}
