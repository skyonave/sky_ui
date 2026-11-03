import 'dart:async';

import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';

import '../../shared/api/api_client.dart';
import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';

class SniPicker extends StatefulComponent {
  const SniPicker({
    required this.api,
    required this.revision,
    required this.onSelected,
    super.key,
  });
  final ApiClient api;
  final int revision;
  final void Function(String) onSelected;
  @override
  State<SniPicker> createState() => _SniPickerState();
}

class _SniPickerState extends State<SniPicker> {
  static const t = AppStrings();
  bool expanded = false, busy = false;
  Map<String, dynamic>? scan;
  String? error;
  int? installReceived, installTotal;
  Timer? timer;
  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    try {
      final value = await component.api.sniScan();
      if (!mounted) return;
      setState(() => scan = value);
      if (value['status'] == 'running') {
        timer?.cancel();
        timer = Timer(const Duration(seconds: 1), refresh);
      }
    } on ApiClientException catch (failure) {
      if (mounted) setState(() => error = failure.code);
    }
  }

  Future<void> perform(Future<void> Function() operation) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation();
    } on ApiClientException catch (failure) {
      if (mounted) setState(() => error = failure.code);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> install() async {
    final job = await component.api.maintain('install-sni-scanner');
    for (var attempt = 0; attempt < 180; attempt++) {
      if (!mounted) return;
      final state = await component.api.maintenance();
      if (mounted && state.job?.id == job.id)
        setState(() {
          installReceived = state.job?.progress?.bytesReceived;
          installTotal = state.job?.progress?.bytesTotal;
        });
      if (state.job?.id == job.id && !state.job!.busy) {
        if (state.job!.status != 'completed')
          throw ApiClientException(state.job!.error ?? 'sni_scan_failed');
        await refresh();
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw const ApiClientException('sni_scan_timeout');
  }

  @override
  Component build(BuildContext context) {
    final running = scan?['status'] == 'running';
    final results = (scan?['results'] as List? ?? []).cast<Map>();
    return div([
      action(
        t('sni.title'),
        () {
          setState(() => expanded = !expanded);
          if (expanded) {
            unawaited(refresh());
          }
        },
        glyph: 'search',
        classes: 'button ghost',
      ),
      if (expanded)
        div([
          p([Component.text(t('sni.description'))], classes: 'muted small'),
          if (busy && scan?['installed'] != true) ...[
            el(
              'progress',
              [],
              attributes: {
                if (installTotal != null && installTotal! > 0) ...{
                  'value': '${installReceived ?? 0}',
                  'max': '$installTotal',
                },
              },
            ),
            if (installReceived != null)
              txt(
                '${(installReceived! / 1000000).toStringAsFixed(1)} MB',
                classes: 'muted small',
              ),
          ],
          if (scan?['supported'] == false)
            txt(t('sni.platform'), classes: 'availability-chip unavailable')
          else if (scan != null && scan?['installed'] != true)
            action(
              busy ? t('sni.installing') : t('sni.install'),
              () => perform(install),
              disabled: busy,
              glyph: 'down',
            )
          else if (scan?['installed'] == true) ...[
            action(
              running ? t('sni.cancel') : t('sni.start'),
              () => perform(() async {
                final value = running
                    ? await component.api.sniScan(cancel: scan!['id'] as String)
                    : await component.api.sniScan(revision: component.revision);
                if (mounted) setState(() => scan = value);
                await refresh();
              }),
              disabled: busy,
              glyph: running ? 'close' : 'search',
            ),
            if (running) ...[
              el(
                'progress',
                [],
                attributes: {
                  'value': '${scan?['completed'] ?? 0}',
                  'max': '${scan?['total'] == 0 ? 64 : scan?['total'] ?? 64}',
                },
              ),
              txt(
                '${scan?['completed'] ?? 0} / ${scan?['total'] ?? 64}',
                classes: 'muted small',
              ),
            ],
            for (final result in results)
              button(
                [
                  txt(result['domain'] as String),
                  txt(
                    '${result['ip']} · TLS ${result['tls']} · ${result['alpn']} · ${result['latencyMs']} ms',
                    classes: 'muted small',
                  ),
                  icon('check'),
                ],
                type: ButtonType.button,
                classes: 'sni-result',
                onClick: () => component.onSelected(result['domain'] as String),
              ),
            if (scan?['status'] == 'completed' && results.isEmpty)
              p([Component.text(t('sni.empty'))], classes: 'muted small'),
          ],
          if (error != null || scan?['status'] == 'failed')
            p([
              Component.text(t('runtime.error.${error ?? scan?['error']}')),
            ], classes: 'field-error'),
          if (scan?['status'] == 'failed')
            el('details', [
              el('summary', [Component.text(t('builder.installDetails'))]),
              el('pre', [
                Component.text(
                  [
                    'Code: ${scan?['error'] ?? '-'}',
                    'Stage: ${scan?['stage'] ?? '-'}',
                    'Targets: ${scan?['completed'] ?? 0}/${scan?['total'] ?? 0}',
                    if (scan?['errorType'] != null)
                      'Type: ${scan?['errorType']}',
                    if (scan?['exitCode'] != null) 'Exit: ${scan?['exitCode']}',
                    if (scan?['osErrorCode'] != null)
                      'OS: ${scan?['osErrorCode']}',
                  ].join('\n'),
                ),
              ]),
            ], classes: 'sni-details'),
          p([Component.text(t('sni.clientCheck'))], classes: 'muted small'),
        ], classes: 'sni-panel'),
    ], classes: 'sni-picker');
  }
}
