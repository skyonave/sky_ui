import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/components/page_helpers.dart';
import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';

class OverviewPage extends StatelessComponent {
  const OverviewPage({
    required this.system,
    required this.samples,
    required this.dataError,
    required this.panelData,
    required this.runtimeStatus,
    required this.enginesReady,
    super.key,
  });
  final SystemSnapshot? system;
  final List<({DateTime time, SystemSnapshot value})> samples;
  final String? dataError;
  final PanelSnapshot? panelData;
  final String runtimeStatus;
  final bool enginesReady;
  final t = const AppStrings();
  @override
  Component build(BuildContext context) {
    final host = system, uptime = system?.uptimeSeconds;
    final total = host?.memoryTotal, available = host?.memoryAvailable;
    final uptimeText = uptime == null
        ? '—'
        : '${uptime ~/ 86400}${t('system.days')} ${uptime % 86400 ~/ 3600}${t('system.hours')} ${uptime % 3600 ~/ 60}${t('system.minutes')}';
    return div([
      heading('overview'),
      div([
        txt('IP', classes: 'muted'),
        txt(
          host == null || host.addresses.isEmpty
              ? '—'
              : host.addresses.join(' · '),
          classes: 'mono',
        ),
      ], classes: 'panel host-address'),
      div([
        metric(
          'system.cpu',
          host?.cpuPercent == null
              ? '—'
              : '${host!.cpuPercent!.toStringAsFixed(1)}%',
          host == null ? '—' : t('system.cores', {'count': '${host.cpuCores}'}),
        ),
        metric(
          'system.memory',
          total == null || available == null ? '—' : bytes(total - available),
          t('system.total', {'value': bytes(total)}),
        ),
        metric(
          'system.disk',
          bytes(host?.diskUsed),
          t('system.total', {'value': bytes(host?.diskTotal)}),
        ),
        metric('system.uptime', uptimeText, host?.hostname ?? '—'),
      ], classes: 'hardware-grid'),
      div([
        graph(
          'CPU',
          host?.cpuPercent == null
              ? '—'
              : '${host!.cpuPercent!.toStringAsFixed(1)}%',
          (v) => v.cpuPercent,
        ),
        graph(
          'RAM',
          total == null || available == null
              ? '—'
              : '${((total - available) / total * 100).toStringAsFixed(1)}%',
          (v) => v.memoryTotal == null || v.memoryAvailable == null
              ? null
              : (v.memoryTotal! - v.memoryAvailable!) / v.memoryTotal! * 100,
        ),
        graph(
          'Network',
          'RX ${rate(host?.rxBytesPerSecond)} · TX ${rate(host?.txBytesPerSecond)}',
          (v) => v.rxBytesPerSecond,
          secondary: (v) => v.txBytesPerSecond,
        ),
      ], classes: 'telemetry-grid'),
      if (host?.supported == false)
        p([Component.text(t('system.unsupported'))], classes: 'notice'),
      div([
        statusRow(
          'system.panel',
          dataError == null && panelData != null
              ? t('status.running')
              : t('runtime.offline'),
          'system.panelHint',
          dataError == null && panelData != null,
        ),
        statusRow(
          'system.configuration',
          panelData?.synchronized == true
              ? t('system.applied')
              : t('runtime.notReady'),
          'system.configurationHint',
          panelData?.synchronized == true,
        ),
        statusRow(
          'nav.core',
          runtimeStatus,
          enginesReady ? 'system.coreHint' : 'system.coreNotReady',
          enginesReady,
        ),
      ], classes: 'panel system-statuses'),
    ]);
  }

  Component metric(String title, String value, String detail) => div([
    txt(t(title), classes: 'muted'),
    txt(value, classes: 'metric-value'),
    txt(detail, classes: 'muted small'),
  ], classes: 'panel hardware-metric');

  Component statusRow(
    String title,
    String value,
    String description,
    bool ready,
  ) => div([
    div([txt(t(title)), txt(t(description), classes: 'muted small')]),
    pill(value, positive: ready),
  ], classes: 'system-status-row');

  Component graph(
    String title,
    String current,
    double? Function(SystemSnapshot) pick, {
    double? Function(SystemSnapshot)? secondary,
  }) {
    final network = secondary != null;
    final end = samples.isEmpty ? DateTime.now() : samples.last.time;
    final start = end.subtract(const Duration(minutes: 5));
    final recent = samples.where((s) => !s.time.isBefore(start)).toList();
    var upper = network ? 1000.0 : 100.0;
    if (network)
      for (final sample in recent) {
        for (final v in [pick(sample.value), secondary(sample.value)])
          if (v != null && v * 1.15 > upper) upper = v * 1.15;
      }
    String path(double? Function(SystemSnapshot) field) {
      final parts = <String>[];
      var active = false;
      for (final sample in recent) {
        final value = field(sample.value);
        if (value == null) {
          active = false;
          continue;
        }
        final x = (sample.time.difference(start).inMilliseconds / 300000 * 600)
            .clamp(0, 600);
        final y = 148 - (value / upper).clamp(0, 1) * 136;
        parts.add(
          '${active ? 'L' : 'M'}${x.toStringAsFixed(2)},${y.toStringAsFixed(2)}',
        );
        active = true;
      }
      return parts.join(' ');
    }

    final enough = recent.where((s) => pick(s.value) != null).length > 1;
    return div([
      div([
        txt(title),
        txt(current, classes: 'mono muted'),
      ], classes: 'graph-heading'),
      div([
        el(
          'svg',
          [
            for (final y in [12, 80, 148])
              el(
                'line',
                [],
                attributes: {
                  'x1': '0',
                  'x2': '600',
                  'y1': '$y',
                  'y2': '$y',
                  'stroke': '#303034',
                  'stroke-width': '1',
                  'vector-effect': 'non-scaling-stroke',
                },
              ),
            el(
              'path',
              [],
              attributes: {
                'd': path(pick),
                'fill': 'none',
                'stroke': '#c7a36c',
                'stroke-width': '1.7',
                'vector-effect': 'non-scaling-stroke',
              },
            ),
            if (secondary != null)
              el(
                'path',
                [],
                attributes: {
                  'd': path(secondary),
                  'fill': 'none',
                  'stroke': '#8ca8b9',
                  'stroke-width': '1.7',
                  'vector-effect': 'non-scaling-stroke',
                },
              ),
          ],
          attributes: {
            'viewBox': '0 0 600 160',
            'preserveAspectRatio': 'none',
            'role': 'img',
            'aria-label': '$title: $current',
          },
          classes: 'telemetry-plot',
        ),
        if (!enough) txt(t('system.collecting'), classes: 'graph-empty muted'),
        txt(network ? rate(upper) : '100%', classes: 'graph-scale muted'),
      ], classes: 'graph-plot'),
      div([
        txt('-5 min'),
        if (network)
          div([
            txt('RX', classes: 'rx-key'),
            txt('TX', classes: 'tx-key'),
          ], classes: 'graph-legend'),
        txt('now'),
      ], classes: 'graph-axis muted'),
    ], classes: 'panel telemetry-card ${network ? 'network-graph' : ''}');
  }
}
