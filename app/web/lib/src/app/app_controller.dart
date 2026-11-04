import 'dart:async';
import 'dart:js_interop';

import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:web/web.dart' as web;

import '../features/runtime/runtime_controller.dart';
import '../features/settings/owner_controller.dart';
import '../features/updates/release_controller.dart';
import '../shared/api/api_client.dart';
import '../shared/localization/strings.dart';
import '../shared/state/panel_store.dart';

/// Cross-feature coordination only. Feature decisions live in their own modules.
class AppController {
  AppController({
    required this.readOwner,
    required this.onSignedOut,
    required this.onOwnerChanged,
    required this.onChanged,
  });
  final OwnerState Function() readOwner;
  final void Function() onSignedOut, onChanged;
  final void Function(OwnerState) onOwnerChanged;
  OwnerState get owner => readOwner();
  bool mounted = true;
  void mutate(void Function() update) {
    if (!mounted) return;
    update();
    onChanged();
  }

  final store = PanelStore();

  PanelSnapshot? panelData;

  bool dataBusy = false;

  bool dataRefreshing = false;

  int dataGeneration = 0;

  int dialogRevision = 0;

  int? settingsRevision;

  CoreSettings? engineSettings;

  final engineSettingsDraft = <String, String>{};

  Map<String, String> engineSettingsErrors = {};

  bool engineSettingsLoading = false;

  int engineSettingsGeneration = 0;

  String? dataError;

  RecipientShare? shareData;

  bool shareLoading = false;

  int shareRevision = 0;

  int shareGeneration = 0;

  String shareSelection = '-1';

  bool get canInspect => panelData != null && !dataBusy;

  bool get canEdit =>
      canInspect &&
      dataError == null &&
      panelData!.synchronized &&
      !observations.runtimeBusy &&
      !maintenanceBusy &&
      observations.runtimes.any(
        (r) => r.platformSupported && r.binaryAvailable,
      );

  final api = ApiClient();

  late final ownerSettings = OwnerController(
    api: api,
    isAlive: () => mounted,
    readOwner: () => owner,
    readModal: () => modal,
    message: observations.runtimeMessage,
    notify: notify,
    onError: (value) => error = value,
    closeModal: closeModal,
    onSignedOut: () => onSignedOut(),
    onOwnerChanged: (value) => onOwnerChanged(value),
    onChanged: () => mutate(() {}),
  );

  late final releases = ReleaseController(
    api: api,
    isAlive: () => mounted,
    onChanged: () => mutate(() {}),
  );

  late final observations = RuntimeController(
    api: api,
    store: store,
    readPanel: () => panelData,
    isDataBusy: () => dataBusy,
    isAlive: () => mounted,
    isLogsPage: () => page == 'logs',
    onSignedOut: () => onSignedOut(),
    onChanged: () => mutate(() {}),
  );

  MaintenanceSnapshot? maintenance;

  MaintenanceJob? maintenanceJob;

  bool maintenanceLoading = false, maintenanceSubmitting = false;

  String? maintenanceBackupId;

  CoreUpdateInfo? updateNotes;

  String? panelUpdateReloadId, panelUpdateTarget;

  String? coreActionFeedback;

  String? actionCore;

  String maintenanceCore = 'mihomo';

  String? updateTag;

  bool get maintenanceBusy =>
      maintenanceSubmitting || maintenanceJob?.busy == true;

  bool clearingLogs = false;

  Timer? runtimeTimer;
  Timer? presenceTimer;

  Future<void> clearLogHistory() async {
    if (observations.runtimeBusy || dataBusy) return;
    observations.logStream?.close();
    observations.logStream = null;
    observations.runtimeGeneration++;
    mutate(() {
      observations.runtimeBusy = true;
      clearingLogs = true;
      observations.logsLive = false;
      error = null;
    });
    var success = false;
    try {
      await api.clearLogs(instanceId: observations.selectedLogInstance);
      final entries = await api.logs(
        instanceId: observations.selectedLogInstance,
      );
      if (mounted) mutate(() => observations.runtimeLogs = entries);
      success = true;
    } on ApiClientException catch (e) {
      if (mounted) mutate(() => error = observations.runtimeMessage(e.code));
    } finally {
      if (mounted)
        mutate(() {
          observations.runtimeBusy = false;
          clearingLogs = false;
        });
      if (mounted) observations.connectLogs();
    }
    if (success && mounted) {
      closeModal();
      notify(t('logs.cleared'));
    }
  }

  Future<void> runCoreAction(
    CoreOperation operation, {
    String instanceId = 'primary',
  }) async {
    final target = observations.runtimes
        .where((r) => r.instanceId == instanceId)
        .firstOrNull;
    if (dataBusy ||
        maintenanceBusy ||
        observations.runtimeBusy ||
        target == null ||
        !target.operations.contains(operation))
      return;
    observations.runtimeGeneration++;
    dataGeneration++;
    mutate(() {
      observations.runtimeBusy = true;
      actionCore = target.coreId;
      coreActionFeedback = null;
    });
    try {
      final value = await api.execute(operation, instanceId: instanceId);
      if (mounted)
        mutate(() {
          if (instanceId == 'primary') observations.runtime = value;
          observations.runtimes = [
            for (final item in observations.runtimes)
              if (item.instanceId == instanceId) value else item,
          ];
          coreActionFeedback = t('core.feedback.${operation.name}');
          observations.runtimeError = null;
          store.running = observations.runtimeRunning;
        });
    } on ApiClientException catch (e) {
      if (mounted) {
        mutate(() => coreActionFeedback = observations.runtimeMessage(e.code));
        notify(observations.runtimeMessage(e.code));
      }
    } finally {
      if (mounted) {
        mutate(() => observations.runtimeBusy = false);
        await observations.refreshRuntime();
        await refreshPanel();
      }
    }
  }

  final t = const AppStrings();

  String page = 'connections';

  String search = '';

  String filter = 'all';

  String? modal;

  String? editingRecipientId;

  Connection? editingConnection;
  Connection? diagnosticConnection;
  void diagnoseConnection(Connection value) {
    if (!canInspect || maintenanceBusy) return;
    diagnosticConnection = value;
    openModal('diagnostics');
  }

  String? error;

  String? toast;

  String? editedServerName;

  String? editedAddress;

  String? deleteKind;

  String? deleteId;

  String? deleteName;

  Recipient? sharing;

  Map<String, String> recipientDraft = {};

  Set<String> recipientGrants = {};

  Timer? toastTimer;

  Timer? maintenanceTimer;

  bool panelUpdateReconnecting = false;

  web.HTMLElement? previousFocus;

  late final JSFunction keyListener;

  late final JSFunction hashListener;

  static const pages = [
    'overview',
    'connections',
    'users',
    'core',
    'logs',
    'settings',
  ];

  void start() {
    api.csrfToken = owner.csrf;
    api.onUnauthorized = () {
      if (mounted) onSignedOut();
    };
    unawaited(ownerSettings.refreshOwnerSessions());
    unawaited(refreshMaintenance());
    unawaited(releases.refreshCoreUpdates());
    unawaited(releases.refreshPanelUpdate());
    store.running = false;
    unawaited(observations.refreshRuntime());
    unawaited(refreshPanel());
    observations.connectLogs();
    maintenanceTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (maintenanceJob?.action == 'panel-https' && maintenanceBusy)
        unawaited(refreshMaintenance());
      if (maintenanceJob?.action == 'panel-update' && maintenanceBusy) {
        unawaited(refreshMaintenance());
        if (mounted) mutate(() {});
      }
    });
    runtimeTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(observations.refreshRuntime());
      unawaited(refreshPanel());
      if (releases.panelUpdateChecked == null ||
          DateTime.now().difference(releases.panelUpdateChecked!) >
              const Duration(hours: 1))
        unawaited(releases.refreshPanelUpdate());
      if (page == 'settings') unawaited(ownerSettings.refreshOwnerSessions());
      if (page == 'core') unawaited(releases.refreshCoreUpdates());
      if (page == 'settings' || page == 'core' || maintenanceBusy)
        unawaited(refreshMaintenance());
    });
    final route = web.window.location.hash.replaceFirst('#', '');
    if (pages.contains(route)) page = route;
    presenceTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (page == 'users') unawaited(observations.refreshPresence());
    });
    hashListener = ((web.Event event) {
      final route = web.window.location.hash.replaceFirst('#', '');
      if (pages.contains(route)) mutate(() => page = route);
      if (page == 'users') unawaited(observations.refreshPresence());
    }).toJS;
    web.window.addEventListener('hashchange', hashListener);
    keyListener = ((web.KeyboardEvent event) {
      if (modal == null) return;
      if (event.key == 'Escape') {
        event.preventDefault();
        closeModal();
      }
      if (event.key != 'Tab') return;
      final nodes = web.document.querySelectorAll(
        '.modal button:not([disabled]), .modal input:not([disabled]), .modal select:not([disabled]), .modal [tabindex="0"]',
      );
      if (nodes.length == 0) return;
      final first = nodes.item(0) as web.HTMLElement;
      final last = nodes.item(nodes.length - 1) as web.HTMLElement;
      if (event.shiftKey && web.document.activeElement == first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && web.document.activeElement == last) {
        event.preventDefault();
        first.focus();
      }
    }).toJS;
    web.document.addEventListener('keydown', keyListener);
  }

  void dispose() {
    mounted = false;
    observations.dispose();
    toastTimer?.cancel();
    runtimeTimer?.cancel();
    presenceTimer?.cancel();
    maintenanceTimer?.cancel();
    web.window.removeEventListener('hashchange', hashListener);
    web.document.removeEventListener('keydown', keyListener);
    web.document.body?.style.overflow = '';
  }

  void navigate(String destination) {
    mutate(() {
      if (page == 'settings' && destination != 'settings') {
        editedServerName = null;
        editedAddress = null;
        settingsRevision = null;
      }
      page = destination;
      search = '';
      filter = 'all';
    });
    web.window.location.hash = destination;
  }

  void notify(String message) {
    toastTimer?.cancel();
    mutate(() => toast = message);
    toastTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) mutate(() => toast = null);
    });
  }

  Future<void> refreshPanel() async {
    if (dataRefreshing || dataBusy || observations.runtimeBusy) return;
    dataRefreshing = true;
    final generation = dataGeneration;
    try {
      final value = await api.panel();
      if (!mounted || generation != dataGeneration) return;
      if (modal == 'share' && value.revision != shareRevision) {
        closeModal();
        notify(t('share.changed'));
      }
      mutate(() {
        panelData = value;
        store.apply(value);
        dataError = null;
      });
    } on ApiClientException catch (e) {
      if (mounted && generation == dataGeneration)
        mutate(() => dataError = e.code);
    } finally {
      dataRefreshing = false;
    }
  }

  Future<bool> changePanel(
    Future<PanelSnapshot> Function() request, {
    bool dismiss = false,
    void Function()? optimistic,
    void Function(ApiClientException)? onError,
  }) async {
    if (!canEdit) return false;
    final previous = panelData!;
    dataGeneration++;
    observations.runtimeGeneration++;
    mutate(() {
      dataBusy = true;
      error = null;
      optimistic?.call();
    });
    var success = false;
    try {
      final value = await request();
      if (!mounted) return false;
      mutate(() {
        panelData = value;
        store.apply(value);
        dataError = null;
        dataBusy = false;
      });
      if (dismiss) closeModal();
      notify(t('common.saved'));
      success = true;
    } on ApiClientException catch (e) {
      onError?.call(e);
      if (mounted) {
        mutate(() {
          store.apply(previous);
        });
        if (modal != null) {
          mutate(() => error = observations.runtimeMessage(e.code));
        } else {
          notify(observations.runtimeMessage(e.code));
        }
      }
    } finally {
      if (mounted) {
        mutate(() => dataBusy = false);
        unawaited(observations.refreshRuntime());
        if (!success) unawaited(refreshPanel());
      }
    }
    return success;
  }

  Future<void> openSharing(Recipient user) async {
    if (dataBusy) return;
    final generation = ++shareGeneration;
    sharing = user;
    shareData = null;
    shareSelection = '-1';
    shareRevision = panelData?.revision ?? 0;
    openModal('share');
    if (!user.enabled) return;
    mutate(() => shareLoading = true);
    try {
      final value = await api.share(user.id);
      if (mounted &&
          generation == shareGeneration &&
          modal == 'share' &&
          sharing?.id == user.id)
        mutate(() {
          shareData = value;
          if (value.links.length == 1 && value.links.single.content != null)
            shareSelection = '0';
        });
    } on ApiClientException catch (e) {
      if (mounted &&
          generation == shareGeneration &&
          modal == 'share' &&
          sharing?.id == user.id)
        mutate(() => error = observations.runtimeMessage(e.code));
    } finally {
      if (mounted && generation == shareGeneration)
        mutate(() => shareLoading = false);
    }
  }

  void openModal(String value) {
    dialogRevision = panelData?.revision ?? 0;
    previousFocus = web.document.activeElement as web.HTMLElement?;
    mutate(() {
      modal = value;
      error = null;
    });
    web.document.body?.style.overflow = 'hidden';
    Timer(const Duration(milliseconds: 30), () {
      (web.document.querySelector('.modal [autofocus], .modal .modal-close')
              as web.HTMLElement?)
          ?.focus();
    });
  }

  void closeModal() {
    if (dataBusy ||
        clearingLogs ||
        ownerSettings.ownerBusy ||
        maintenanceSubmitting)
      return;
    ownerSettings.ownerDraft.clear();
    engineSettingsGeneration++;
    shareGeneration++;
    shareLoading = false;
    shareData = null;
    mutate(() {
      modal = null;
      error = null;
    });
    web.document.body?.style.overflow = '';
    Timer(const Duration(milliseconds: 30), () => previousFocus?.focus());
  }

  void newConnection([Connection? connection]) {
    if (!canInspect) return;
    editingConnection = connection;
    openModal('connection');
  }

  void editRecipient([Recipient? recipient]) {
    if (!canInspect) return;
    editingRecipientId = recipient?.id;
    recipientDraft = {'name': recipient?.name ?? ''};
    recipientGrants = {...?recipient?.connectionIds};
    openModal('recipient');
  }

  Future<void> saveRecipient() async {
    final name = recipientDraft['name']?.trim() ?? '';
    if (name.isEmpty) {
      mutate(() => error = t('common.invalidName'));
      return;
    }
    final old = store.recipients
        .where((u) => u.id == editingRecipientId)
        .firstOrNull;
    final value = Recipient(
      id: editingRecipientId ?? '',
      name: name,
      enabled: old?.enabled ?? true,
      connectionIds: recipientGrants.toList(),
    );
    final id = editingRecipientId;
    await changePanel(
      () => api.saveRecipient(dialogRevision, value, id: id),
      dismiss: true,
    );
  }

  Future<void> toggleConnection(Connection c) async {
    final value = c.copyWith(enabled: !c.enabled);
    await changePanel(
      () => api.saveConnection(panelData!.revision, value, id: c.id),
      optimistic: () => store.connections = store.connections
          .map((v) => v.id == c.id ? value : v)
          .toList(),
    );
  }

  Future<void> toggleRecipient(Recipient user) async {
    final value = user.copyWith(enabled: !user.enabled);
    await changePanel(
      () => api.saveRecipient(panelData!.revision, value, id: user.id),
      optimistic: () => store.recipients = store.recipients
          .map((v) => v.id == user.id ? value : v)
          .toList(),
    );
  }

  void confirmDelete(String kind, String id, String name) {
    if (!canEdit) return;
    deleteKind = kind;
    deleteId = id;
    deleteName = name;
    openModal('delete');
  }

  Future<void> performDelete() async {
    final kind = deleteKind!;
    final id = deleteId!;
    await changePanel(
      () => api.delete(dialogRevision, kind, id),
      dismiss: true,
    );
  }

  Future<void> openEngineSettings(String id) async {
    final generation = ++engineSettingsGeneration;
    engineSettings = null;
    engineSettingsDraft.clear();
    engineSettingsErrors = {};
    engineSettingsLoading = true;
    openModal('coreSettings');
    try {
      final value = await api.coreSettings(id);
      if (mounted && generation == engineSettingsGeneration)
        mutate(() {
          engineSettings = value;
          engineSettingsDraft.addAll(value.values);
        });
    } on ApiClientException catch (e) {
      if (mounted && generation == engineSettingsGeneration)
        mutate(() => error = observations.runtimeMessage(e.code));
    } finally {
      if (mounted && generation == engineSettingsGeneration)
        mutate(() => engineSettingsLoading = false);
    }
  }

  Future<void> saveEngineSettings() async {
    final settings = engineSettings;
    if (settings == null || dataBusy) return;
    engineSettingsErrors = {};
    await changePanel(
      () => api.saveCoreSettings(settings, {...engineSettingsDraft}),
      dismiss: true,
      onError: (e) => engineSettingsErrors = e.fields,
    );
  }

  Future<void> refreshMaintenance() async {
    if (maintenanceLoading) return;
    maintenanceLoading = true;
    try {
      final value = await api.maintenance();
      if (mounted && value.job?.action == 'panel-update') {
        if (value.job!.busy) panelUpdateReloadId = value.job!.id;
        if (value.job!.status == 'completed' &&
            value.job!.id == panelUpdateReloadId) {
          panelUpdateReloadId = null;
          web.window.location.reload();
          return;
        }
      }
      if (mounted)
        mutate(() {
          maintenance = value;
          maintenanceJob = value.job;
          panelUpdateReconnecting = false;
        });
    } on ApiClientException {
      // The worker briefly stops the API. Keep the durable job visible until it returns.
      if (mounted &&
          maintenanceJob?.action == 'panel-update' &&
          maintenanceBusy)
        mutate(() => panelUpdateReconnecting = true);
    } finally {
      maintenanceLoading = false;
    }
  }

  Future<void> prepareCoreUpdate([String core = 'mihomo']) async {
    await releases.refreshCoreUpdates();
    final value = releases.engineUpdates[core];
    if (!mounted || value?.available != true || releases.updatesError != null)
      return;
    maintenanceCore = core;
    updateNotes = value;
    updateTag = updateNotes!.versions.first;
    openModal(observations.coreInstalled(core) ? 'coreUpdate' : 'coreInstall');
  }

  Future<void> submitMaintenance(String action) async {
    if (maintenanceBusy) return;
    mutate(() => maintenanceSubmitting = true);
    try {
      final job = await api.maintain(
        action,
        core: ['install', 'remove', 'update'].contains(action)
            ? maintenanceCore
            : null,
        backupId: action == 'restore' ? maintenanceBackupId : null,
        tag: action == 'panel-update'
            ? panelUpdateTarget
            : ['update', 'install'].contains(action)
            ? updateTag
            : null,
      );
      if (mounted)
        mutate(() {
          maintenanceJob = job;
          if (action == 'panel-update') panelUpdateReloadId = job.id;
        });
    } on ApiClientException catch (e) {
      if (mounted) {
        mutate(() => error = observations.runtimeMessage(e.code));
        return;
      }
    } finally {
      if (mounted) mutate(() => maintenanceSubmitting = false);
    }
    if (mounted) closeModal();
  }

  Future<void> submitPanelHttps(String domain, String expected) async {
    if (maintenanceBusy) throw const ApiClientException('maintenance_busy');
    mutate(() => maintenanceSubmitting = true);
    try {
      final job = await api.changePanelHttps(domain, expected);
      mutate(() => maintenanceJob = job);
    } finally {
      mutate(() => maintenanceSubmitting = false);
    }
  }

  void editOwner(bool password) {
    ownerSettings.ownerDraft.clear();
    ownerSettings.ownerDraft['username'] = owner.username ?? '';
    openModal(password ? 'ownerPassword' : 'ownerName');
  }

  Future<void> saveGeneralSettings() async {
    final name = (editedServerName ?? store.serverName).trim();
    final address = (editedAddress ?? store.address).trim();
    if (name.isEmpty || address.isEmpty) {
      notify(t('common.required'));
      return;
    }
    if (await changePanel(
      () => api.saveSettings(
        settingsRevision ?? panelData!.revision,
        name,
        address,
      ),
    )) {
      mutate(() {
        editedServerName = null;
        editedAddress = null;
        settingsRevision = null;
      });
    }
  }

  void selectLogInstance(String id) {
    mutate(() {
      observations.runtimeGeneration++;
      observations.selectedLogInstance = id;
      observations.runtimeLogs = [];
      observations.followingLogs = true;
    });
    observations.connectLogs();
    unawaited(observations.refreshRuntime());
  }
}
