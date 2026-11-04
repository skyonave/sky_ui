import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:web/web.dart' as web;

import '../features/connections/connection_wizard.dart';
import '../features/connections/connections_page.dart';
import '../features/connections/diagnostics_dialog.dart';
import '../features/engines/engine_card.dart';
import '../features/logs/logs_page.dart';
import '../features/maintenance/backup_panel.dart';
import '../features/overview/overview_page.dart';
import '../features/recipients/recipient_form.dart';
import '../features/recipients/recipients_page.dart';
import '../features/recipients/share_content.dart';
import '../features/settings/owner_form.dart';
import '../features/settings/session_list.dart';
import '../features/settings/settings_page.dart';
import '../features/settings/https_panel.dart';
import '../features/updates/update_card.dart';
import '../shared/api/api_client.dart';
import '../shared/components/page_helpers.dart';
import '../shared/components/primitives.dart';
import '../shared/forms/protocol_field.dart';
import '../shared/localization/strings.dart';
import '../shared/protocols/catalog.dart';
import 'app_controller.dart';
import 'sidebar.dart';

class AppView extends StatelessComponent {
  const AppView({
    required this.controller,
    required this.onLocaleChanged,
    super.key,
  });
  final AppController controller;
  final void Function(String) onLocaleChanged;
  final t = const AppStrings();
  static const appVersion = String.fromEnvironment(
    'SKY_UI_VERSION',
    defaultValue: '1.0.0',
  );
  @override
  Component build(BuildContext context) => div([
    sidebar(),
    div(
      [
        el('header', [
          div([
            txt(t('app.name'), classes: 'compact-brand'),
            icon('server'),
            txt(controller.store.serverName, classes: 'server-name'),
            txt('/', classes: 'breadcrumb-slash'),
            txt(t('nav.${controller.page}')),
          ], classes: 'breadcrumb'),
          div([
            span([], classes: 'status-dot'),
            txt(
              t(
                controller.dataBusy
                    ? 'data.applying'
                    : controller.panelData == null
                    ? 'runtime.loading'
                    : controller.dataError != null
                    ? 'runtime.offline'
                    : 'runtime.connectedLabel',
              ),
            ),
          ], classes: 'demo-badge'),
        ], classes: 'topbar'),
        el(
          'main',
          [
            if (controller.panelData?.errorCode != null)
              div([
                icon('info'),
                Component.text(
                  controller.observations.runtimeMessage(
                    controller.panelData!.errorCode!,
                  ),
                ),
              ], classes: 'notice'),
            if (controller.page == 'connections')
              controller.panelData == null
                  ? emptyState(
                      'server',
                      t(
                        controller.dataError == null
                            ? 'runtime.loading'
                            : 'runtime.offline',
                      ),
                    )
                  : connectionsPage(),
            if (controller.page == 'users')
              controller.panelData == null
                  ? emptyState(
                      'users',
                      t(
                        controller.dataError == null
                            ? 'runtime.loading'
                            : 'runtime.offline',
                      ),
                    )
                  : usersPage(),
            if (controller.page == 'overview') overviewPage(),
            if (controller.page == 'core') corePage(),
            if (controller.page == 'logs') logsPage(),
            if (controller.page == 'settings') settingsPage(),
            el('footer', [
              txt('${t('app.name')} / $appVersion'),
            ], classes: 'page-footer'),
          ],
          classes:
              'main-content ${controller.page == 'logs' ? 'logs-layout' : ''}',
        ),
      ],
      classes: 'workspace',
      attributes: {if (controller.modal != null) 'inert': ''},
    ),
    if (controller.modal != null) modalView(),
    if (controller.toast != null)
      div(
        [
          icon('check'),
          Component.text(controller.toast!),
          iconButton(
            'close',
            t('common.close'),
            () => controller.mutate(() => controller.toast = null),
          ),
        ],
        classes: 'toast',
        attributes: {'role': 'status', 'aria-live': 'polite'},
      ),
  ], classes: 'app-shell');

  Component sidebar() => AppSidebar(
    page: controller.page,
    username: controller.owner.username,
    busy: controller.ownerSettings.ownerBusy,
    inert: controller.modal != null,
    connectionCount: controller.store.connections.length,
    panelUpdateCard: panelUpdateCard,
    navigate: controller.navigate,
    onSignOut: controller.ownerSettings.signOut,
  );

  Component connectionsPage() => ConnectionsPage(
    store: controller.store,
    filter: controller.filter,
    search: controller.search,
    canInspect: controller.canInspect,
    canEdit: controller.canEdit,
    dataBusy: controller.dataBusy,
    runtimeStatus: controller.observations.runtimeStatus,
    coreInstalled: controller.observations.coreInstalled,
    newConnection: controller.newConnection,
    toggleConnection: controller.toggleConnection,
    confirmDelete: controller.confirmDelete,
    onFilter: (v) => controller.mutate(() => controller.filter = v),
    onSearch: (v) => controller.mutate(() => controller.search = v),
    onDiagnose: controller.diagnoseConnection,
  );

  Component usersPage() => RecipientsPage(
    store: controller.store,
    presence: controller.observations.presence,
    canInspect: controller.canInspect,
    canEdit: controller.canEdit,
    editRecipient: controller.editRecipient,
    toggleRecipient: controller.toggleRecipient,
    openSharing: controller.openSharing,
    confirmDelete: controller.confirmDelete,
  );

  Component overviewPage() => OverviewPage(
    system: controller.observations.system,
    samples: controller.observations.samples,
    dataError: controller.dataError,
    panelData: controller.panelData,
    runtimeStatus: controller.observations.runtimeStatus,
    enginesReady: controller.observations.enginesReady,
  );

  Component corePage() => div([
    heading('core'),
    maintenanceStatus(),
    div([
      for (final descriptor in coreCatalog) engineCard(descriptor),
    ], classes: 'engine-list'),
  ], classes: 'core-page');

  Component engineCard(CoreDescriptor descriptor) {
    final value = controller.observations.runtimes
        .where((r) => r.coreId == descriptor.id)
        .firstOrNull;
    return EngineCard(
      descriptor: descriptor,
      runtime: value,
      strings: t,
      updateAvailable:
          controller.releases.engineUpdates[descriptor.id]?.available == true,
      maintenanceAvailable: controller.maintenance?.available == true,
      busy:
          controller.dataBusy ||
          controller.observations.runtimeBusy ||
          controller.maintenanceBusy,
      feedback:
          value?.processState == CoreProcessState.failed && value?.error != null
          ? controller.observations.runtimeMessage(value!.error!.code)
          : controller.actionCore == descriptor.id &&
                controller.coreActionFeedback != null
          ? controller.coreActionFeedback
          : value?.binaryAvailable == true && value?.error != null
          ? controller.observations.runtimeMessage(value!.error!.code)
          : null,
      onOperation: (operation) => unawaited(
        controller.runCoreAction(operation, instanceId: value!.instanceId),
      ),
      onInstallOrUpdate: () =>
          unawaited(controller.prepareCoreUpdate(descriptor.id)),
      settingsAvailable:
          controller.panelData?.settingsInstances.contains(value?.instanceId) ==
              true &&
          controller.canEdit,
      onSettings: () =>
          unawaited(controller.openEngineSettings(value!.instanceId)),
      onRemove: () {
        controller.maintenanceCore = descriptor.id;
        controller.openModal('coreRemove');
      },
    );
  }

  Component engineSettingsForm() => div([
    if (controller.engineSettingsLoading)
      txt(t('common.loading'), classes: 'muted'),
    if (controller.engineSettings != null) ...[
      txt(controller.engineSettings!.coreId, classes: 'availability-chip'),
      for (final group in ['dns', 'access', 'logs'])
        el('section', [
          h3([Component.text(t('coreSettings.group.$group'))]),
          div([
            for (final field in controller.engineSettings!.fields.where(
              (f) =>
                  f.group == group && f.visible(controller.engineSettingsDraft),
            ))
              ProtocolFieldView(
                field: field,
                values: controller.engineSettingsDraft,
                prefix: 'engine-',
                busy: controller.dataBusy,
                error: controller.engineSettingsErrors[field.id],
                onChanged: (value, rebuild) => controller.mutate(() {
                  controller.engineSettingsDraft[field.id] = value;
                  controller.engineSettingsErrors.remove(field.id);
                  controller.error = null;
                }),
                key: ValueKey('engine-${field.id}'),
              ),
          ], classes: 'form-grid'),
        ], classes: 'core-settings-section'),
      p([Component.text(t('coreSettings.applyHint'))], classes: 'muted small'),
    ],
  ], classes: 'core-settings-form');

  Component logsPage() => LogsPage(
    runtimeLogs: controller.observations.runtimeLogs,
    selectedLogLevels: controller.observations.selectedLogLevels,
    logsLive: controller.observations.logsLive,
    runtimes: controller.observations.runtimes,
    selectedLogInstance: controller.observations.selectedLogInstance,
    runtimeBusy: controller.observations.runtimeBusy,
    runtimeOnline: controller.observations.runtimeOnline,
    followingLogs: controller.observations.followingLogs,
    onInstance: controller.selectLogInstance,
    onLevels: (levels) => controller.mutate(() {
      controller.observations.selectedLogLevels
        ..clear()
        ..addAll(levels);
      controller.observations.followingLogs = true;
    }),
    onFollow: (value) =>
        controller.mutate(() => controller.observations.followingLogs = value),
    onClear: () => controller.openModal('clearLogs'),
    scheduleLogTail: controller.observations.scheduleLogTail,
    runtimeMessage: controller.observations.runtimeMessage,
  );

  Component settingsPage() => SettingsPage(
    store: controller.store,
    onLocaleChanged: onLocaleChanged,
    panelData: controller.panelData,
    editedServerName: controller.editedServerName,
    editedAddress: controller.editedAddress,
    canEdit: controller.canEdit,
    ownerBusy: controller.ownerSettings.ownerBusy,
    owner: controller.owner,
    ownerSessions: controller.ownerSettings.ownerSessions,
    coreInstalled: controller.observations.coreInstalled,
    onName: (v) {
      controller.settingsRevision ??= controller.panelData?.revision;
      controller.editedServerName = v;
    },
    onAddress: (v) {
      controller.settingsRevision ??= controller.panelData?.revision;
      controller.editedAddress = v;
    },
    onSave: controller.saveGeneralSettings,
    editOwner: controller.editOwner,
    onRevokeOthers: () {
      controller.ownerSettings.revokeSessionId = null;
      controller.openModal('revokeSession');
    },
    openEngineSettings: controller.openEngineSettings,
    backupPanel: backupPanel,
    sessionList: sessionList,
    httpsPanel: HttpsPanel(
      api: controller.api,
      job: controller.maintenanceJob?.action == 'panel-https'
          ? controller.maintenanceJob
          : null,
      blocked:
          controller.maintenanceBusy ||
          controller.dataBusy ||
          controller.observations.runtimeBusy,
      submit: controller.submitPanelHttps,
    ),
  );

  Component panelUpdateCard() {
    final updating =
        controller.maintenanceJob?.action == 'panel-update' &&
        controller.maintenanceBusy;
    final failed =
        controller.maintenanceJob?.action == 'panel-update' &&
        controller.maintenanceJob?.status == 'failed';
    return PanelUpdateCard(
      info: controller.releases.panelUpdateInfo,
      job: controller.maintenanceJob?.action == 'panel-update'
          ? controller.maintenanceJob
          : null,
      reconnecting: controller.panelUpdateReconnecting,
      onDetails: () => controller.openModal('panelUpdateDetails'),
      checking: controller.releases.panelUpdateLoading,
      updating: updating,
      busy: controller.maintenanceBusy,
      checkedManually: controller.releases.panelUpdateManualChecked,
      checkError: controller.releases.panelUpdateError == null
          ? null
          : t('panelUpdate.checkFailed'),
      updateError: failed && !controller.releases.panelUpdateManualChecked
          ? controller.observations.runtimeMessage(
              controller.maintenanceJob!.error ?? 'panel_update_failed',
            )
          : null,
      updateEnabled: controller.maintenance?.available == true,
      onCheck: () => controller.releases.refreshPanelUpdate(refresh: true),
      onUpdate: () {
        controller.panelUpdateTarget = controller.releases.panelUpdateInfo?.tag;
        controller.releases.panelUpdateManualChecked = false;
        controller.openModal('panelUpdate');
      },
    );
  }

  Component maintenanceStatus() {
    final job = controller.maintenanceJob;
    return div(
      [
        if (job != null)
          txt(
            job.status == 'failed'
                ? controller.observations.runtimeMessage(
                    job.error ?? 'maintenance_failed',
                  )
                : t('maintenance.status.${job.status}'),
            classes: job.status == 'failed' ? 'form-error' : 'muted small',
          ),
      ],
      attributes: {'role': 'status', 'aria-live': 'polite'},
    );
  }

  Component backupPanel() => BackupPanel(
    maintenance: controller.maintenance,
    maintenanceBusy: controller.maintenanceBusy,
    maintenanceLoading: controller.maintenanceLoading,
    appVersion: appVersion,
    maintenanceStatus: maintenanceStatus,
    onCreate: () => controller.openModal('backup'),
    onRestore: (id) {
      controller.maintenanceBackupId = id;
      controller.openModal('restore');
    },
  );

  Component ownerForm() => OwnerForm(
    ownerDraft: controller.ownerSettings.ownerDraft,
    ownerBusy: controller.ownerSettings.ownerBusy,
    password: controller.modal == 'ownerPassword',
  );

  Component sessionList() => SessionList(
    ownerSessions: controller.ownerSettings.ownerSessions,
    ownerBusy: controller.ownerSettings.ownerBusy,
    onRevoke: (id) {
      controller.ownerSettings.revokeSessionId = id;
      controller.openModal('revokeSession');
    },
  );

  Component modalView() => controller.modal == 'diagnostics'
      ? ConnectionDiagnosticsDialog(
          api: controller.api,
          connection: controller.diagnosticConnection!,
          revision: controller.panelData?.revision ?? controller.dialogRevision,
          onClose: controller.closeModal,
        )
      : controller.modal == 'connection'
      ? ConnectionWizard(
          api: controller.api,
          store: controller.store,
          revision: controller.dialogRevision,
          initial: controller.editingConnection,
          canInspect: controller.canInspect,
          canEdit: controller.canEdit,
          dataBusy: controller.dataBusy,
          maintenanceBusy: controller.maintenanceBusy,
          job: controller.maintenanceJob,
          coreInstalled: controller.observations.coreInstalled,
          onClose: controller.closeModal,
          onSave: (revision, value) async {
            ApiClientException? failure;
            final saved = await controller.changePanel(
              () => controller.api.saveConnection(
                revision,
                value,
                id: value.id.isEmpty ? null : value.id,
              ),
              dismiss: true,
              onError: (e) => failure = e,
            );
            if (failure != null) throw failure!;
            return saved;
          },
          onJob: (job) =>
              controller.mutate(() => controller.maintenanceJob = job),
          onMaintenance: (status) => controller.mutate(() {
            controller.maintenance = status;
            controller.maintenanceJob = status.job;
          }),
          onInstalled: (data, cores) => controller.mutate(() {
            controller.observations.runtimes = cores;
            controller.panelData = data;
            controller.store.apply(data);
          }),
        )
      : div([
          div(
            [
              div([
                div([
                  h2([
                    Component.text(
                      t(switch (controller.modal) {
                        'recipient' =>
                          controller.editingRecipientId == null
                              ? 'users.add'
                              : 'common.edit',
                        'share' => 'share.title',
                        'clearLogs' => 'logs.clearTitle',
                        'ownerName' => 'admin.editName',
                        'ownerPassword' => 'admin.changePassword',
                        'revokeSession' => 'admin.revokeTitle',
                        'backup' => 'maintenance.create',
                        'restore' => 'maintenance.restore',
                        'coreUpdate' => 'core.update',
                        'coreInstall' => 'core.install',
                        'coreRemove' => 'core.remove',
                        'coreSettings' => 'coreSettings.title',
                        'panelUpdate' => 'panelUpdate.title',
                        'panelUpdateDetails' => 'panelUpdate.details',
                        _ => 'modal.deleteTitle',
                      }),
                    ),
                  ], id: 'modal-title'),
                ]),
                iconButton(
                  'close',
                  t('common.close'),
                  controller.closeModal,
                  classes: 'icon-button modal-close',
                  disabled:
                      controller.dataBusy ||
                      controller.clearingLogs ||
                      controller.ownerSettings.ownerBusy,
                ),
              ], classes: 'modal-header'),
              div([
                if (controller.modal == 'coreSettings') engineSettingsForm(),
                if (controller.modal == 'panelUpdateDetails')
                  PanelUpdateDetails(
                    job: controller.maintenanceJob?.action == 'panel-update'
                        ? controller.maintenanceJob
                        : null,
                    info: controller.releases.panelUpdateInfo,
                    checkError: controller.releases.panelUpdateError,
                  ),
                if (controller.modal == 'recipient') recipientForm(),
                if (controller.modal == 'share') shareContent(),
                if (controller.modal == 'clearLogs')
                  p([Component.text(t('logs.clearHint'))]),
                if (controller.modal == 'backup')
                  p([Component.text(t('maintenance.backupHint'))]),
                if (controller.modal == 'restore')
                  p([Component.text(t('maintenance.restoreHint'))]),
                if (controller.modal == 'panelUpdate') ...[
                  txt(
                    'v${controller.releases.panelUpdateInfo?.currentVersion ?? appVersion} → ${controller.panelUpdateTarget ?? '—'}',
                    classes: 'mono',
                  ),
                  p([Component.text(t('panelUpdate.hint'))]),
                ],
                if (controller.modal == 'coreRemove')
                  p([Component.text(t('core.removeHint'))]),
                if (controller.modal == 'coreUpdate' ||
                    controller.modal == 'coreInstall') ...[
                  if (controller.updateNotes == null &&
                      controller.error == null)
                    txt(t('maintenance.loading')),
                  if (controller.updateNotes != null) ...[
                    label([
                      Component.text(t('core.version')),
                      select(
                        [
                          for (final tag in controller.updateNotes!.versions)
                            option(
                              [Component.text(tag)],
                              value: tag,
                              selected: tag == controller.updateTag,
                            ),
                        ],
                        value: controller.updateTag,
                        onChange: (value) => controller.mutate(
                          () => controller.updateTag = value.first,
                        ),
                      ),
                    ]),
                    txt(
                      '${controller.maintenanceCore} · ${controller.observations.runtimes.where((c) => c.coreId == controller.maintenanceCore).firstOrNull?.version ?? '—'} → ${controller.updateTag}',
                      classes: 'mono',
                    ),
                    p([
                      Component.text(
                        t(
                          controller.modal == 'coreInstall'
                              ? 'core.installHint'
                              : 'maintenance.updateHint',
                        ),
                      ),
                    ]),
                  ],
                ],
                if (controller.modal == 'ownerName' ||
                    controller.modal == 'ownerPassword')
                  ownerForm(),
                if (controller.modal == 'revokeSession')
                  p([
                    Component.text(
                      t(
                        controller.ownerSettings.revokeSessionId == null
                            ? 'admin.revokeOthersHint'
                            : 'admin.revokeHint',
                      ),
                    ),
                  ]),
                if (controller.modal == 'delete')
                  p([
                    Component.text(
                      t('modal.deleteHint', {'name': controller.deleteName!}),
                    ),
                  ]),
                if (controller.error != null)
                  div(
                    [icon('info'), Component.text(controller.error!)],
                    classes: 'form-error',
                    attributes: {'role': 'alert'},
                  ),
              ], classes: 'modal-body'),
              if (controller.modal != 'share')
                div([
                  div([
                    action(
                      t(
                        controller.modal == 'panelUpdateDetails'
                            ? 'common.close'
                            : 'common.cancel',
                      ),
                      controller.closeModal,
                      disabled:
                          controller.dataBusy ||
                          controller.clearingLogs ||
                          controller.ownerSettings.ownerBusy,
                    ),
                    if (controller.modal == 'panelUpdateDetails')
                      action(t('common.copy'), () async {
                        try {
                          await web.window.navigator.clipboard
                              .writeText(
                                const JsonEncoder.withIndent('  ').convert({
                                  'currentVersion': controller
                                      .releases
                                      .panelUpdateInfo
                                      ?.currentVersion,
                                  'latestVersion': controller
                                      .releases
                                      .panelUpdateInfo
                                      ?.latestVersion,
                                  'checkError':
                                      controller.releases.panelUpdateError,
                                  'job':
                                      controller.maintenanceJob?.action ==
                                          'panel-update'
                                      ? controller.maintenanceJob?.toJson()
                                      : null,
                                }),
                              )
                              .toDart;
                          controller.notify(t('common.copied'));
                        } catch (_) {
                          controller.notify(t('common.copyFailed'));
                        }
                      }, glyph: 'copy'),
                    if (controller.modal == 'ownerName' ||
                        controller.modal == 'ownerPassword')
                      action(
                        t('common.save'),
                        () => unawaited(controller.ownerSettings.saveOwner()),
                        classes: 'button primary',
                        disabled: controller.ownerSettings.ownerBusy,
                      ),
                    if (controller.modal == 'coreSettings')
                      action(
                        t(
                          controller.dataBusy
                              ? 'coreSettings.applying'
                              : 'coreSettings.apply',
                        ),
                        () => unawaited(controller.saveEngineSettings()),
                        classes: 'button primary',
                        disabled:
                            controller.engineSettingsLoading ||
                            controller.engineSettings == null ||
                            !controller.canEdit,
                      ),
                    if (controller.modal == 'revokeSession')
                      action(
                        t('admin.revoke'),
                        () => unawaited(
                          controller.ownerSettings.revokeOwnerSessions(),
                        ),
                        classes: 'button danger',
                        disabled: controller.ownerSettings.ownerBusy,
                      ),

                    if (controller.modal == 'recipient')
                      action(
                        t('common.save'),
                        controller.saveRecipient,
                        disabled: !controller.canEdit,
                        classes: 'button primary',
                      ),
                    if (controller.modal == 'clearLogs')
                      action(
                        t('logs.clear'),
                        () => unawaited(controller.clearLogHistory()),
                        classes: 'button danger',
                        disabled:
                            controller.clearingLogs ||
                            controller.observations.runtimeBusy,
                      ),
                    if (controller.modal == 'backup' ||
                        controller.modal == 'restore' ||
                        controller.modal == 'coreUpdate' ||
                        controller.modal == 'coreInstall' ||
                        controller.modal == 'coreRemove')
                      action(
                        t(
                          controller.modal == 'backup'
                              ? 'maintenance.create'
                              : controller.modal == 'restore'
                              ? 'maintenance.restore'
                              : controller.modal == 'coreRemove'
                              ? 'core.remove'
                              : controller.modal == 'coreInstall'
                              ? 'core.install'
                              : 'core.update',
                        ),
                        () => unawaited(
                          controller.submitMaintenance(
                            controller.modal == 'backup'
                                ? 'backup'
                                : controller.modal == 'restore'
                                ? 'restore'
                                : controller.modal == 'coreRemove'
                                ? 'remove'
                                : controller.modal == 'coreInstall'
                                ? 'install'
                                : 'update',
                          ),
                        ),
                        classes:
                            'button ${['restore', 'coreRemove'].contains(controller.modal) ? 'danger' : 'primary'}',
                        disabled:
                            controller.maintenanceBusy ||
                            ([
                                  'coreUpdate',
                                  'coreInstall',
                                ].contains(controller.modal) &&
                                (controller.updateNotes == null ||
                                    !controller.updateNotes!.versions.contains(
                                      controller.updateTag,
                                    ))),
                      ),
                    if (controller.modal == 'panelUpdate')
                      action(
                        t('panelUpdate.update'),
                        () => unawaited(
                          controller.submitMaintenance('panel-update'),
                        ),
                        classes: 'button primary',
                        disabled:
                            controller.maintenanceBusy ||
                            controller.releases.panelUpdateInfo?.available !=
                                true,
                      ),
                    if (controller.modal == 'delete')
                      action(
                        t('common.delete'),
                        controller.performDelete,
                        disabled: !controller.canEdit,
                        classes: 'button danger',
                      ),
                  ], classes: 'modal-footer-actions'),
                ], classes: 'modal-footer'),
            ],
            classes:
                'modal ${controller.modal == 'coreSettings' ? 'wide' : ''}',
            attributes: {
              'role': 'dialog',
              'aria-modal': 'true',
              'aria-labelledby': 'modal-title',
            },
          ),
        ], classes: 'modal-overlay');

  Component recipientForm() => RecipientForm(
    store: controller.store,
    draft: controller.recipientDraft,
    grants: controller.recipientGrants,
    busy:
        controller.dataBusy ||
        controller.clearingLogs ||
        controller.ownerSettings.ownerBusy,
    onGrant: (id, v) => controller.mutate(() {
      if (v) {
        controller.recipientGrants.add(id);
      } else {
        controller.recipientGrants.remove(id);
      }
    }),
  );

  Component shareContent() => ShareContent(
    sharing: controller.sharing!,
    shareLoading: controller.shareLoading,
    shareData: controller.shareData,
    shareSelection: controller.shareSelection,
    onSelection: (v) => controller.mutate(() => controller.shareSelection = v),
    notify: controller.notify,
  );
}
