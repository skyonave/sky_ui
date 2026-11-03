import 'dart:async';
import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import '../../shared/api/api_client.dart';
import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';
import '../../shared/protocols/catalog.dart';

class ConnectionDiagnosticsDialog extends StatefulComponent {
  const ConnectionDiagnosticsDialog({
    required this.api,
    required this.connection,
    required this.revision,
    required this.onClose,
    super.key,
  });
  final ApiClient api;
  final Connection connection;
  final int revision;
  final void Function() onClose;
  @override
  State<ConnectionDiagnosticsDialog> createState() => _DiagnosticsState();
}

class _DiagnosticsState extends State<ConnectionDiagnosticsDialog> {
  final t = const AppStrings();
  ConnectionDiagnostics? report;
  String? error;
  bool starting = false, polling = false, reconnecting = false, lost = false;
  int generation = 0;
  Timer? timer;
  DateTime? pollStarted;
  bool get busy => starting || report?.running == true && !lost;

  @override
  void initState() {
    super.initState();
    unawaited(start());
  }

  Future<void> cancel(String id) async {
    try {
      await component.api.cancelDiagnostics(component.connection.id, id);
    } on Object {
      /* Closing never pins a report dialog. The server also has a hard deadline. */
    }
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    if (report?.running == true) unawaited(cancel(report!.id));
    super.dispose();
  }

  Future<void> start() async {
    if (busy) return;
    final current = ++generation;
    timer?.cancel();
    setState(() {
      starting = true;
      error = null;
      reconnecting = false;
      lost = false;
      report = null;
    });
    try {
      final value = await component.api.startDiagnostics(
        component.connection.id,
        component.revision,
      );
      if (!mounted || current != generation) {
        if (value.running) unawaited(cancel(value.id));
        return;
      }
      setState(() => report = value);
      pollStarted = DateTime.now();
      if (value.running)
        timer = Timer.periodic(
          const Duration(milliseconds: 700),
          (_) => unawaited(poll(current)),
        );
    } on ApiClientException catch (e) {
      if (mounted && current == generation) setState(() => error = e.code);
    } finally {
      if (mounted && current == generation) setState(() => starting = false);
    }
  }

  Future<void> poll(int current) async {
    if (polling || report?.running != true || current != generation) return;
    polling = true;
    try {
      final value = await component.api.diagnostics(
        component.connection.id,
        report!.id,
      );
      if (!mounted || current != generation) return;
      setState(() {
        report = value;
        reconnecting = false;
      });
      if (!value.running) timer?.cancel();
    } on ApiClientException catch (e) {
      if (!mounted || current != generation) return;
      final expired =
          e.code == 'not_found' ||
          DateTime.now().difference(pollStarted!).inSeconds >= 90;
      setState(() {
        reconnecting = !expired;
        if (expired) {
          lost = true;
          error = e.code;
        }
      });
      if (expired) timer?.cancel();
    } finally {
      polling = false;
    }
  }

  String errorText(String code) {
    final key = 'diagnostics.error.$code', text = t(key);
    if (text != key) return text;
    final runtime = 'runtime.error.$code', fallback = t(runtime);
    return fallback == runtime ? t('diagnostics.error.failed') : fallback;
  }

  String duration(int milliseconds) => milliseconds < 1000
      ? '$milliseconds ms'
      : '${(milliseconds / 1000).toStringAsFixed(1)} s';

  Component row(DiagnosticCheck check) => div(
    [
      span([
        if (check.state == DiagnosticState.passed)
          icon('check')
        else if (check.state == DiagnosticState.failed ||
            check.state == DiagnosticState.warning)
          icon('info')
        else if (check.state == DiagnosticState.running)
          icon('refresh')
        else
          txt('—'),
      ], classes: 'diagnostic-symbol'),
      div([
        div([
          txt(t('diagnostics.step.${check.kind}')),
          txt(
            t('diagnostics.state.${check.state.name}'),
            classes: 'availability-chip',
          ),
          if (check.durationMs != null)
            txt(
              duration(check.durationMs!),
              classes: 'muted diagnostic-duration',
            ),
        ], classes: 'diagnostic-row-heading'),
        if (check.finished)
          p([
            Component.text(t('diagnostics.code.${check.code}')),
          ], classes: 'diagnostic-description muted'),
        if (check.details.isNotEmpty)
          div([
            for (final detail in check.details.entries)
              span([
                txt(
                  '${t('diagnostics.detail.${detail.key}')}: ',
                  classes: 'muted',
                ),
                txt(detail.value, classes: 'mono'),
              ], classes: 'diagnostic-detail'),
          ], classes: 'diagnostic-details'),
      ], classes: 'diagnostic-row-content'),
    ],
    classes: 'diagnostic-row diagnostic-${check.state.name}',
    key: ValueKey(check.id),
  );

  @override
  Component build(BuildContext context) {
    final value = report;
    final issue =
        value?.checks
            .where((c) => c.state == DiagnosticState.failed)
            .firstOrNull ??
        value?.checks
            .where((c) => c.state == DiagnosticState.warning)
            .firstOrNull;
    final current = value?.checks
        .where((c) => c.state == DiagnosticState.running)
        .firstOrNull;
    final end = DateTime.tryParse(value?.finishedAt ?? '') ?? DateTime.now();
    final started = DateTime.tryParse(value?.startedAt ?? '');
    final elapsed = started == null
        ? null
        : end.difference(started).inMilliseconds.clamp(0, 3600000);
    return div([
      div(
        [
          div([
            div([
              h2([Component.text(t('diagnostics.title'))], id: 'modal-title'),
              txt(
                '${component.connection.name} · ${coreName(component.connection.coreId)}',
                classes: 'muted small',
              ),
            ]),
            iconButton(
              'close',
              t('common.close'),
              component.onClose,
              classes: 'icon-button modal-close',
            ),
          ], classes: 'modal-header'),
          div([
            div(
              [
                div([
                  txt(
                    t(
                      starting
                          ? 'diagnostics.starting'
                          : 'diagnostics.outcome.${value?.outcome ?? 'pending'}',
                    ),
                  ),
                  p([
                    Component.text(
                      issue != null
                          ? t('diagnostics.issue', {
                              'step': t('diagnostics.step.${issue.kind}'),
                              'reason': t('diagnostics.code.${issue.code}'),
                            })
                          : current != null
                          ? t('diagnostics.current', {
                              'step': t('diagnostics.step.${current.kind}'),
                            })
                          : value?.status == 'cancelled'
                          ? t('diagnostics.code.cancelled')
                          : value?.running == false
                          ? t('diagnostics.code.snapshot_current')
                          : '',
                    ),
                  ], classes: 'diagnostic-summary-detail muted'),
                ], classes: 'diagnostic-summary-result'),
                if (value != null)
                  txt(
                    '${value.completed}/${value.checks.length}',
                    classes: 'mono muted',
                  ),
                if (elapsed != null)
                  txt(duration(elapsed), classes: 'mono muted'),
              ],
              classes: 'diagnostic-summary',
              attributes: {'role': 'status', 'aria-live': 'polite'},
            ),
            div(
              [
                div(
                  [],
                  classes: 'diagnostic-progress-fill',
                  attributes: {
                    'style':
                        'width:${value == null || value.checks.isEmpty ? 0 : value.completed / value.checks.length * 100}%',
                  },
                ),
              ],
              classes: 'diagnostic-progress',
              attributes: {
                'role': 'progressbar',
                'aria-label': t('diagnostics.progress'),
                'aria-valuemin': '0',
                'aria-valuemax': '${value?.checks.length ?? 1}',
                'aria-valuenow': '${value?.completed ?? 0}',
              },
            ),
            if (reconnecting)
              p([
                Component.text(t('diagnostics.reconnecting')),
              ], classes: 'notice'),
            if (error != null)
              div(
                [icon('info'), Component.text(errorText(error!))],
                classes: 'form-error',
                attributes: {'role': 'alert'},
              ),
            div([
              if (value != null)
                for (final check in value.checks) row(check),
            ], classes: 'diagnostic-checks'),
          ], classes: 'modal-body'),
          div([
            p([
              Component.text(t('diagnostics.scope')),
            ], classes: 'muted small diagnostic-scope'),
            div([
              action(t('common.close'), component.onClose),
              action(
                t('diagnostics.retry'),
                () => unawaited(start()),
                glyph: 'refresh',
                disabled: busy,
                classes: 'button primary',
              ),
            ], classes: 'modal-footer-actions'),
          ], classes: 'modal-footer'),
        ],
        classes: 'modal wide diagnostic-dialog',
        attributes: {
          'role': 'dialog',
          'aria-modal': 'true',
          'aria-labelledby': 'modal-title',
        },
      ),
    ], classes: 'modal-overlay');
  }
}
