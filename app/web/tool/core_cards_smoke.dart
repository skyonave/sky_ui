import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:sky_ui_web/src/engine_card.dart';
import 'package:sky_ui_web/src/i18n.dart';
import 'package:sky_ui_web/src/protocol_catalog.dart';
import 'package:sky_ui_web/src/ui.dart';

// Visual fixture only. Uses the production card; no owner APIs or persistence.
void main() => runApp(const CoreCardsSmoke(), attachTo: '#app');

class CoreCardsSmoke extends StatefulComponent {
  const CoreCardsSmoke({super.key});
  @override
  State<CoreCardsSmoke> createState() => _CoreCardsSmoke();
}

class _CoreCardsSmoke extends State<CoreCardsSmoke> {
  final t = const AppStrings();
  final values = <String, CoreSnapshot>{}, feedback = <String, String>{};
  String? removing;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    scenario(Uri.base.queryParameters['state'] ?? 'mixed');
  }

  void scenario(String state) {
    values.clear();
    feedback.clear();
    removing = null;
    busy = state == 'busy';
    for (final (index, core) in coreCatalog.indexed) {
      final installed = state != 'mixed' || index < 2;
      final failed = state == 'error' && core.id == 'xray';
      final active = installed && index != 1 && !failed;
      values[core.id] = CoreSnapshot(
        instanceId: core.id == 'mihomo' ? 'primary' : core.id,
        coreId: core.id,
        name: core.name,
        service: 'sky-ui-${core.id}.service',
        platformSupported: true,
        binaryAvailable: installed,
        processState: !installed
            ? CoreProcessState.unavailable
            : failed
            ? CoreProcessState.failed
            : active
            ? CoreProcessState.active
            : CoreProcessState.inactive,
        desiredState: active
            ? CoreDesiredState.running
            : CoreDesiredState.stopped,
        controllerReady: active,
        version: installed
            ? ['v1.19.33', 'v1.14.4', 'v26.10.31', 'v3.1.20260828'][index]
            : null,
        memoryBytes: active
            ? [7400000, 32000000, 18500000, 11600000][index]
            : null,
        operations: installed
            ? [CoreOperation.start, CoreOperation.stop, CoreOperation.restart]
            : [],
      );
      if (failed) feedback[core.id] = t('runtime.error.service_failed');
    }
  }

  void operate(String core, CoreOperation operation) {
    final active = operation != CoreOperation.stop;
    setState(() {
      values[core] = CoreSnapshot.fromJson({
        ...values[core]!.toJson(),
        'processState': active ? 'active' : 'inactive',
        'controllerReady': active,
        'memoryBytes': active ? 7400000 : null,
      });
      feedback[core] = t('core.feedback.${operation.name}');
    });
  }

  @override
  Component build(BuildContext context) => div([
    el('aside', [
      div([
        div([icon('bolt')], classes: 'brand-mark'),
        div([
          el('strong', [Component.text('Sky UI')]),
        ], classes: 'brand-text'),
      ], classes: 'brand'),
      el('nav', [
        txt(t('nav.workspace'), classes: 'nav-label'),
        for (final item in [
          ('grid', 'nav.overview'),
          ('connections', 'nav.connections'),
          ('users', 'nav.users'),
          ('core', 'nav.core'),
          ('logs', 'nav.logs'),
          ('settings', 'nav.settings'),
        ])
          button([
            icon(item.$1),
            txt(t(item.$2)),
          ], classes: 'nav-item ${item.$1 == 'core' ? 'selected' : ''}'),
      ], classes: 'navigation'),
      div([
        div([
          txt('admin', classes: 'owner-name'),
          icon('logout'),
        ], classes: 'owner'),
      ], classes: 'sidebar-bottom'),
    ], classes: 'sidebar'),
    div([
      div([
        div([
          icon('server'),
          txt('sky-server', classes: 'server-name'),
          txt('/', classes: 'breadcrumb-slash'),
          txt(t('nav.core')),
        ], classes: 'breadcrumb'),
        txt('UI preview', classes: 'muted'),
      ], classes: 'topbar'),
      el('main', [
        div([
          h1([Component.text(t('core.title'))]),
          div([
            for (final state in ['mixed', 'all', 'error', 'busy'])
              action(
                state,
                () => setState(() => scenario(state)),
                classes: 'button compact ghost',
              ),
          ], classes: 'core-actions'),
        ], classes: 'page-heading'),
        div([
          for (final core in coreCatalog)
            EngineCard(
              descriptor: core,
              runtime: values[core.id],
              feedback: feedback[core.id],
              busy: busy,
              maintenanceAvailable: true,
              updateAvailable: core.id != 'mihomo',
              onOperation: (operation) => operate(core.id, operation),
              onInstallOrUpdate: () =>
                  setState(() => feedback[core.id] = t('core.installHint')),
              onRemove: () => setState(() => removing = core.id),
            ),
        ], classes: 'engine-list'),
        el('footer', [txt('Sky UI / 0.8.0-dev.2')], classes: 'page-footer'),
      ], classes: 'main-content core-page'),
    ], classes: 'workspace'),
    if (removing != null)
      div([
        div([
          div([
            h2([Component.text('${t('core.remove')}: $removing')]),
            iconButton(
              'close',
              t('common.cancel'),
              () => setState(() => removing = null),
            ),
          ], classes: 'modal-header'),
          div([
            p([Component.text(t('core.removeHint'))]),
          ], classes: 'modal-body'),
          div([
            action(t('common.cancel'), () => setState(() => removing = null)),
          ], classes: 'modal-footer'),
        ], classes: 'modal'),
      ], classes: 'modal-overlay'),
  ], classes: 'app-shell');
}
