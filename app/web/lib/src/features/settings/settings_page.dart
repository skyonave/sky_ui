import 'dart:async';

import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/components/page_helpers.dart';
import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';
import '../../shared/protocols/catalog.dart';
import '../../shared/state/panel_store.dart';

class SettingsPage extends StatelessComponent {
  const SettingsPage({
    required this.store,
    required this.panelData,
    required this.editedServerName,
    required this.editedAddress,
    required this.canEdit,
    required this.ownerBusy,
    required this.owner,
    required this.ownerSessions,
    required this.coreInstalled,
    required this.onName,
    required this.onAddress,
    required this.onSave,
    required this.editOwner,
    required this.onRevokeOthers,
    required this.openEngineSettings,
    required this.backupPanel,
    required this.sessionList,
    required this.httpsPanel,
    super.key,
  });
  final PanelStore store;
  final PanelSnapshot? panelData;
  final String? editedServerName;
  final String? editedAddress;
  final bool canEdit;
  final bool ownerBusy;
  final OwnerState owner;
  final List<OwnerSession> ownerSessions;
  final bool Function(String) coreInstalled;
  final void Function(String) onName;
  final void Function(String) onAddress;
  final void Function() onSave;
  final void Function(bool) editOwner;
  final void Function() onRevokeOthers;
  final Future<void> Function(String) openEngineSettings;
  final Component Function() backupPanel;
  final Component Function() sessionList;
  final Component httpsPanel;
  final t = const AppStrings();
  @override
  Component build(BuildContext context) => div([
    heading('settings'),
    backupPanel(),
    div([
      h2([Component.text(t('settings.general'))]),
      div([
        label([
          Component.text(t('settings.serverName')),
          input<String>(
            value: editedServerName ?? store.serverName,
            onInput: (v) {
              onName(v);
            },
            attributes: {'maxlength': '80'},
          ),
        ]),
        label([
          Component.text(t('settings.address')),
          input<String>(
            value: editedAddress ?? store.address,
            onInput: (v) {
              onAddress(v);
            },
            attributes: {'maxlength': '253'},
          ),
        ]),
      ], classes: 'form-grid'),
      p([Component.text(t('settings.addressHelp'))], classes: 'muted small'),
      div([
        div([txt(t('settings.language'))]),
        txt(t('settings.russian'), classes: 'setting-value'),
      ], classes: 'setting-row'),
      div([
        div([txt(t('settings.appearance'))]),
        span([
          icon('moon'),
          Component.text(t('settings.dark')),
        ], classes: 'setting-value'),
      ], classes: 'setting-row'),

      action(
        t('common.save'),
        onSave,
        classes: 'button primary',
        disabled: !canEdit,
      ),
    ], classes: 'panel settings-panel'),
    div([
      h2([Component.text(t('admin.title'))]),

      div([
        div([
          txt(t('admin.username')),
          pill(owner.username ?? ''),
        ], classes: 'setting-label'),
        action(t('common.edit'), () => editOwner(false), disabled: ownerBusy),
      ], classes: 'setting-row'),
      div([
        txt(t('admin.password')),
        action(
          t('admin.changePassword'),
          () => editOwner(true),
          disabled: ownerBusy,
        ),
      ], classes: 'setting-row'),
      div([
        txt(t('admin.sessions')),
        action(t('admin.revokeOthers'), () {
          onRevokeOthers();
        }, disabled: ownerBusy || ownerSessions.length < 2),
      ], classes: 'setting-row'),
      sessionList(),
    ], classes: 'panel settings-panel'),
    httpsPanel,
    div([
      h2([Component.text(t('settings.system'))]),
      for (final descriptor in coreCatalog.where(
        (c) =>
            panelData?.settingsInstances.contains(store.instanceIds[c.id]) ==
            true,
      ))
        div([
          div([
            txt(t('coreSettings.forCore', {'core': descriptor.name})),
            if (!coreInstalled(descriptor.id))
              txt(t('core.notInstalled'), classes: 'availability-chip'),
          ], classes: 'setting-label'),
          action(
            t('settings.configure'),
            () => unawaited(
              openEngineSettings(store.instanceIds[descriptor.id]!),
            ),
            disabled: !canEdit || !coreInstalled(descriptor.id),
          ),
        ], classes: 'setting-row'),
    ], classes: 'panel settings-panel'),
  ]);
}
