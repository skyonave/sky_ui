import 'dart:async';

import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/api/api_client.dart';
import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';

class HttpsPanel extends StatefulComponent {
  const HttpsPanel({
    required this.api,
    required this.job,
    required this.blocked,
    required this.submit,
    super.key,
  });

  final ApiClient api;
  final MaintenanceJob? job;
  final bool blocked;
  final Future<void> Function(String, String) submit;

  @override
  State<HttpsPanel> createState() => _HttpsPanelState();
}

class _HttpsPanelState extends State<HttpsPanel> {
  final t = const AppStrings();
  PanelHttpsStatus? current;
  Timer? timer;
  String? draft, error;
  bool loading = false, confirming = false, submitting = false;
  bool get busy => submitting || component.job?.busy == true;

  @override
  void initState() {
    super.initState();
    unawaited(refresh());
    timer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(refresh()),
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> refresh() async {
    if (loading) return;
    loading = true;
    try {
      final value = await component.api.panelHttps();
      if (!mounted) return;
      setState(() {
        if (current?.domain != value.domain && current != null) {
          confirming = false;
          if (draft?.trim().toLowerCase() == value.domain) draft = null;
        }
        current = value;
        if (error == 'load') error = null;
      });
    } on ApiClientException {
      if (mounted && current == null) setState(() => error = 'load');
    } finally {
      loading = false;
    }
  }

  Future<void> apply(String domain, String expected) async {
    if (busy || component.blocked) return;
    setState(() {
      submitting = true;
      error = null;
    });
    try {
      await component.submit(domain, expected);
      if (mounted) setState(() => confirming = false);
    } on ApiClientException catch (e) {
      if (mounted) setState(() => error = e.code);
    } finally {
      if (mounted) setState(() => submitting = false);
    }
  }

  String errorMessage(String code) {
    final key = 'settings.https.error.$code';
    return t(key) == key ? t('settings.https.error.generic') : t(key);
  }

  Component _link(String name) => el(
    'a',
    [txt('https://$name')],
    attributes: {
      'href': Uri.https(name, '/').toString(),
      'target': '_blank',
      'rel': 'noopener noreferrer',
    },
  );

  Component _address(String label, String name) {
    final expires = DateTime.tryParse(current?.expiresAt[name] ?? '');
    final status = expires == null
        ? t('settings.https.certificateUnknown')
        : expires.isBefore(DateTime.now())
        ? t('settings.https.certificateExpired')
        : t('settings.https.certificateUntil', {
            'date': expires.toLocal().toString().substring(0, 16),
          });
    return div([
      div([txt(t(label)), _link(name)], classes: 'setting-label'),
      pill(status),
    ], classes: 'setting-row');
  }

  @override
  Component build(BuildContext context) {
    final data = current, job = component.job;
    final value = draft?.trim().toLowerCase() ?? data?.domain ?? '';
    final valid = validPanelDomain(value);
    final blocked = busy || component.blocked;
    final target = (job?.domain ?? value).isEmpty
        ? data?.ip ?? ''
        : job?.domain ?? value;
    return div([
      h2([txt(t('settings.domain'))]),
      if (data == null)
        txt(
          error == null ? t('common.loading') : errorMessage(error!),
          classes: 'muted',
        )
      else if (!data.available)
        p([txt(t('settings.https.unavailable'))], classes: 'muted small')
      else ...[
        _address('settings.https.ip', data.ip),
        if (data.domain.isNotEmpty)
          _address('settings.https.domain', data.domain),
        p([txt(t('settings.https.renewal'))], classes: 'muted small'),
        label([
          txt(t('settings.https.newDomain')),
          input<String>(
            value: draft ?? data.domain,
            disabled: blocked || confirming,
            onInput: (v) => setState(() {
              draft = v;
              error = null;
            }),
            attributes: {
              'placeholder': 'panel.example.com',
              'maxlength': '253',
            },
          ),
        ]),
        p([txt(t('settings.https.dnsHelp'))], classes: 'muted small'),
        if (!valid) txt(errorMessage('domain_invalid'), classes: 'error'),
        if (confirming) ...[
          p([txt(t('settings.https.confirm'))], classes: 'muted small'),
          div([
            action(
              t('common.cancel'),
              () => setState(() => confirming = false),
              disabled: blocked,
            ),
            action(
              t('settings.https.apply'),
              () => unawaited(apply(value, data.domain)),
              classes: 'button primary',
              disabled: blocked || !valid,
            ),
          ], classes: 'row-actions'),
        ] else
          action(
            t('settings.https.review'),
            () => setState(() => confirming = true),
            disabled: blocked || !valid || value == data.domain,
          ),
        if (job?.busy == true) ...[
          p([
            txt(t('settings.https.stage.${job!.progress?.stage ?? 'queued'}')),
          ], classes: 'muted small'),
          p([
            txt(t('settings.https.reconnect')),
            txt(' '),
            _link(data.ip),
          ], classes: 'muted small'),
          if (target.isNotEmpty && target != data.ip) _link(target),
        ],
        if (job?.status == 'completed' && target.isNotEmpty)
          p([txt(t('settings.https.done')), txt(' '), _link(target)]),
        if (error != null || job?.status == 'failed')
          p([
            txt(errorMessage(error ?? job?.error ?? 'generic')),
            if (job?.progress?.stage == 'rollback' &&
                job?.error != 'domain_rollback_failed')
              txt(' ${t('settings.https.restored')}'),
          ], classes: 'error'),
      ],
    ], classes: 'panel settings-panel');
  }
}
