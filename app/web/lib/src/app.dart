import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:qr/qr.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:web/web.dart' as web;
import 'panel_store.dart';
import 'protocol_catalog.dart';
import 'i18n.dart';
import 'ui.dart';
import 'field_help.dart';
import 'api_client.dart';
import 'protocol_field.dart';
import 'panel_update_card.dart';
import 'core_install_progress.dart';

class SkyApp extends StatefulComponent {
  const SkyApp({
    required this.owner,
    required this.onSignedOut,
    required this.onOwnerChanged,
    super.key,
  });
  final OwnerState owner;
  final void Function() onSignedOut;
  final void Function(OwnerState) onOwnerChanged;
  @override
  State<SkyApp> createState() => _SkyAppState();
}

class _SkyAppState extends State<SkyApp> {
  static const appVersion = String.fromEnvironment(
    'SKY_UI_VERSION',
    defaultValue: '0.7.0-dev.4',
  );
  final store = PanelStore();
  PanelSnapshot? panelData;
  bool dataBusy = false, ownerBusy = false, ownerSessionsLoading = false;
  final ownerDraft = <String, String>{};
  List<OwnerSession> ownerSessions = [];
  String? revokeSessionId;
  bool dataRefreshing = false;
  int dataGeneration = 0;
  int draftRevision = 0;
  int? settingsRevision;
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
      !runtimeBusy &&
      !maintenanceBusy &&
      runtimes.any((r) => r.platformSupported && r.binaryAvailable);
  final api = ApiClient();
  MaintenanceSnapshot? maintenance;
  MaintenanceJob? maintenanceJob;
  bool maintenanceLoading = false, maintenanceSubmitting = false;
  String? maintenanceBackupId;
  CoreUpdateInfo? updateNotes;
  CoreUpdateInfo? coreUpdates;
  PanelUpdateInfo? panelUpdateInfo;
  bool panelUpdateLoading = false;
  bool panelUpdateManualChecked = false;
  String? panelUpdateError, panelUpdateReloadId, panelUpdateTarget;
  DateTime? panelUpdateChecked;
  bool updatesLoading = false;
  String? updatesError;
  String? coreActionFeedback;
  String? actionCore;
  String maintenanceCore = 'mihomo';
  String selectedLogInstance = 'primary';
  final engineUpdates = <String, CoreUpdateInfo>{};
  String? updateTag;
  bool get maintenanceBusy =>
      maintenanceSubmitting || maintenanceJob?.busy == true;
  CoreSnapshot? runtime;
  List<CoreSnapshot> runtimes = [];
  List<CoreLogEntry> runtimeLogs = [];
  SystemSnapshot? system;
  bool systemRefreshing = false,
      followingLogs = true,
      logsLive = false,
      clearingLogs = false;
  final selectedLogLevels = <String>{
    'debug',
    'info',
    'warning',
    'error',
    'fatal',
  };
  final samples = <({DateTime time, SystemSnapshot value})>[];
  web.EventSource? logStream;
  String? runtimeError;
  bool runtimeBusy = false;
  bool runtimeRefreshing = false;
  int runtimeGeneration = 0;
  Timer? runtimeTimer;

  bool get runtimeOnline => runtime != null && runtimeError == null;
  bool get runtimeRunning =>
      runtimeOnline &&
      runtimes.any((r) => r.processState == CoreProcessState.active);
  bool get enginesReady =>
      runtimeRunning &&
      runtimes
          .where((r) => r.processState == CoreProcessState.active)
          .every((r) => panelData?.instanceReadiness[r.instanceId] == true);
  String get runtimeStatus => !runtimeOnline
      ? t(runtimeError == null ? 'runtime.loading' : 'runtime.offline')
      : !runtimes.any((r) => r.binaryAvailable)
      ? t('core.notInstalled')
      : runtimeRunning
      ? t(enginesReady ? 'status.running' : 'runtime.notReady')
      : t('status.stopped');

  bool coreInstalled(String id) => runtimeOnline && runtime!.coreId == id
      ? runtime!.binaryAvailable
      : panelData?.coreAvailability[id] ?? false;

  String runtimeMessage(String code) {
    final key = 'runtime.error.$code';
    final value = t(key);
    return value == key ? t('runtime.error.internal_error') : value;
  }

  Future<void> refreshRuntime() async {
    if (runtimeRefreshing || runtimeBusy || dataBusy) return;
    runtimeRefreshing = true;
    final generation = runtimeGeneration;
    try {
      unawaited(refreshSystem());
      final values = await Future.wait<Object>([
        api.cores(),
        api.logs(instanceId: selectedLogInstance),
      ]);
      if (!mounted || generation != runtimeGeneration) return;
      setState(() {
        runtimes = values[0] as List<CoreSnapshot>;
        runtime = runtimes.where((v) => v.instanceId == 'primary').firstOrNull;
        if (!logsLive) runtimeLogs = values[1] as List<CoreLogEntry>;
        runtimeError = null;
        store.running = runtimeRunning;
      });
    } on ApiClientException catch (e) {
      if (mounted && generation == runtimeGeneration)
        setState(() {
          runtimeError = e.code;
          store.running = false;
        });
    } finally {
      runtimeRefreshing = false;
    }
  }

  Future<void> refreshSystem() async {
    if (systemRefreshing) return;
    systemRefreshing = true;
    try {
      final value = await api.system();
      if (mounted)
        setState(() {
          system = value;
          samples.add((time: DateTime.now(), value: value));
          if (samples.length > 61) samples.removeAt(0);
        });
    } on Object {
    } finally {
      systemRefreshing = false;
    }
  }

  void connectLogs() {
    logStream?.close();
    final source = web.EventSource(
      '/api/v1/cores/$selectedLogInstance/logs/events',
    );
    logStream = source;
    source.addEventListener(
      'auth_expired',
      ((web.Event _) {
        if (mounted && logStream == source) {
          source.close();
          component.onSignedOut();
        }
      }).toJS,
    );
    source.addEventListener(
      'open',
      ((web.Event _) {
        if (mounted && logStream == source) setState(() => logsLive = true);
      }).toJS,
    );
    source.addEventListener(
      'error',
      ((web.Event _) {
        if (mounted && logStream == source) setState(() => logsLive = false);
      }).toJS,
    );
    source.addEventListener(
      'message',
      ((web.MessageEvent event) {
        try {
          final raw = (event.data as JSString).toDart;
          final entries = (jsonDecode(raw) as List)
              .map(
                (v) =>
                    CoreLogEntry.fromJson(Map<String, dynamic>.from(v as Map)),
              )
              .toList();
          if (mounted && logStream == source)
            setState(() => runtimeLogs = entries);
        } on Object {}
      }).toJS,
    );
  }

  void scheduleLogTail() {
    if (!followingLogs || page != 'logs') return;
    Timer(const Duration(milliseconds: 20), () {
      if (!mounted || !followingLogs || page != 'logs') return;
      final view =
          web.document.querySelector('.runtime-log') as web.HTMLElement?;
      if (view != null) view.scrollTop = view.scrollHeight.toDouble();
    });
  }

  Future<void> clearLogHistory() async {
    if (runtimeBusy || dataBusy) return;
    logStream?.close();
    logStream = null;
    runtimeGeneration++;
    setState(() {
      runtimeBusy = true;
      clearingLogs = true;
      logsLive = false;
      error = null;
    });
    var success = false;
    try {
      await api.clearLogs(instanceId: selectedLogInstance);
      final entries = await api.logs(instanceId: selectedLogInstance);
      if (mounted) setState(() => runtimeLogs = entries);
      success = true;
    } on ApiClientException catch (e) {
      if (mounted) setState(() => error = runtimeMessage(e.code));
    } finally {
      if (mounted)
        setState(() {
          runtimeBusy = false;
          clearingLogs = false;
        });
      if (mounted) connectLogs();
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
    final target = runtimes
        .where((r) => r.instanceId == instanceId)
        .firstOrNull;
    if (dataBusy ||
        maintenanceBusy ||
        runtimeBusy ||
        target == null ||
        !target.operations.contains(operation))
      return;
    runtimeGeneration++;
    dataGeneration++;
    setState(() {
      runtimeBusy = true;
      actionCore = target.coreId;
      coreActionFeedback = null;
    });
    try {
      final value = await api.execute(operation, instanceId: instanceId);
      if (mounted)
        setState(() {
          if (instanceId == 'primary') runtime = value;
          runtimes = [
            for (final item in runtimes)
              if (item.instanceId == instanceId) value else item,
          ];
          coreActionFeedback = t('core.feedback.${operation.name}');
          runtimeError = null;
          store.running = runtimeRunning;
        });
    } on ApiClientException catch (e) {
      if (mounted) {
        setState(() => coreActionFeedback = runtimeMessage(e.code));
        notify(runtimeMessage(e.code));
      }
    } finally {
      if (mounted) {
        setState(() => runtimeBusy = false);
        await refreshRuntime();
        await refreshPanel();
      }
    }
  }

  final t = const AppStrings();
  String page = 'connections';
  String search = '';
  String filter = 'all';
  String? modal;
  String? editingId;
  String? selectedProtocol;
  String connectionStep = 'protocol';
  bool dependencyBusy = false;
  int dependencyGeneration = 0;
  String? dependencyMessage;
  String? dependencyJobId;
  bool dependencyReconnecting = false;
  List<String> candidateEngines(String protocol) => [
    for (final id in productProtocol(protocol)?.engines ?? <String>[])
      if (store.supports(id, protocol)) id,
  ];
  Map<String, String> connectionErrors = {};
  final advancedGroups = <String>{};
  String? selectedCore;
  String? error;
  String? toast;
  String? editedServerName;
  String? editedAddress;
  String? deleteKind;
  String? deleteId;
  String? deleteName;
  Recipient? sharing;
  Map<String, String> draft = {};
  Set<String> grants = {};
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

  @override
  void initState() {
    super.initState();
    api.csrfToken = component.owner.csrf;
    api.onUnauthorized = () {
      if (mounted) component.onSignedOut();
    };
    unawaited(refreshOwnerSessions());
    unawaited(refreshMaintenance());
    unawaited(refreshCoreUpdates());
    unawaited(refreshPanelUpdate());
    store.running = false;
    unawaited(refreshRuntime());
    unawaited(refreshPanel());
    connectLogs();
    maintenanceTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (maintenanceJob?.action == 'panel-update' && maintenanceBusy) {
        unawaited(refreshMaintenance());
        if (mounted) setState(() {});
      }
    });
    runtimeTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(refreshRuntime());
      unawaited(refreshPanel());
      if (panelUpdateChecked == null ||
          DateTime.now().difference(panelUpdateChecked!) >
              const Duration(minutes: 1))
        unawaited(refreshPanelUpdate());
      if (page == 'settings') unawaited(refreshOwnerSessions());
      if (page == 'core') unawaited(refreshCoreUpdates());
      if (page == 'settings' || page == 'core' || maintenanceBusy)
        unawaited(refreshMaintenance());
    });
    final route = web.window.location.hash.replaceFirst('#', '');
    if (pages.contains(route)) page = route;
    hashListener = ((web.Event event) {
      final route = web.window.location.hash.replaceFirst('#', '');
      if (pages.contains(route)) setState(() => page = route);
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

  @override
  void dispose() {
    logStream?.close();
    toastTimer?.cancel();
    runtimeTimer?.cancel();
    maintenanceTimer?.cancel();
    web.window.removeEventListener('hashchange', hashListener);
    web.document.removeEventListener('keydown', keyListener);
    web.document.body?.style.overflow = '';
    super.dispose();
  }

  void navigate(String destination) {
    setState(() {
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
    setState(() => toast = message);
    toastTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => toast = null);
    });
  }

  Future<void> refreshPanel() async {
    if (dataRefreshing || dataBusy || runtimeBusy) return;
    dataRefreshing = true;
    final generation = dataGeneration;
    try {
      final value = await api.panel();
      if (!mounted || generation != dataGeneration) return;
      if (modal == 'share' && value.revision != shareRevision) {
        closeModal();
        notify(t('share.changed'));
      }
      setState(() {
        panelData = value;
        store.apply(value);
        dataError = null;
      });
    } on ApiClientException catch (e) {
      if (mounted && generation == dataGeneration)
        setState(() => dataError = e.code);
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
    runtimeGeneration++;
    setState(() {
      dataBusy = true;
      error = null;
      optimistic?.call();
    });
    var success = false;
    try {
      final value = await request();
      if (!mounted) return false;
      setState(() {
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
        setState(() {
          store.apply(previous);
        });
        if (modal != null) {
          setState(() => error = runtimeMessage(e.code));
        } else {
          notify(runtimeMessage(e.code));
        }
      }
    } finally {
      if (mounted) {
        setState(() => dataBusy = false);
        unawaited(refreshRuntime());
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
    setState(() => shareLoading = true);
    try {
      final value = await api.share(user.id);
      if (mounted &&
          generation == shareGeneration &&
          modal == 'share' &&
          sharing?.id == user.id)
        setState(() {
          shareData = value;
          if (value.links.length == 1 && value.links.single.content != null)
            shareSelection = '0';
        });
    } on ApiClientException catch (e) {
      if (mounted &&
          generation == shareGeneration &&
          modal == 'share' &&
          sharing?.id == user.id)
        setState(() => error = runtimeMessage(e.code));
    } finally {
      if (mounted && generation == shareGeneration)
        setState(() => shareLoading = false);
    }
  }

  void openModal(String value) {
    draftRevision = panelData?.revision ?? 0;
    previousFocus = web.document.activeElement as web.HTMLElement?;
    setState(() {
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
    if (dataBusy || clearingLogs || ownerBusy || maintenanceSubmitting) return;
    ownerDraft.clear();
    dependencyGeneration++;
    dependencyBusy = false;
    shareGeneration++;
    shareLoading = false;
    shareData = null;
    setState(() {
      modal = null;
      error = null;
    });
    web.document.body?.style.overflow = '';
    Timer(const Duration(milliseconds: 30), () => previousFocus?.focus());
  }

  void newConnection([Connection? connection]) {
    if (!canInspect) return;
    editingId = connection?.id;
    dependencyGeneration++;
    connectionStep = connection == null ? 'protocol' : 'parameters';
    dependencyMessage = null;
    dependencyJobId = null;
    dependencyReconnecting = false;
    connectionErrors = {};
    advancedGroups.clear();
    selectedProtocol = connection?.protocolId;
    selectedCore = connection?.coreId;
    draft = connection == null
        ? {'name': '', 'port': '8443'}
        : {
            'name': connection.name,
            'port': '${connection.port}',
            ...connection.settings,
            for (final key in connection.configuredSecrets)
              '_stored:$key': 'true',
          };
    if (connection != null) {
      for (final f in store.protocol(connection.protocolId).fields) {
        draft.putIfAbsent(f.id, () => f.defaultValue);
      }
    }
    openModal('connection');
  }

  void chooseCore(String coreId) {
    if (!store.supports(coreId, selectedProtocol)) return;
    setState(() {
      selectedCore = coreId;
      connectionErrors = {};
      final definition = store.definition(coreId, selectedProtocol!);
      draft = definition.defaults({
        for (final f in definition.fields)
          if (draft[f.id] != null) f.id: draft[f.id]!,
        'name': draft['name'] ?? '',
        'port': draft['port'] ?? '8443',
      });
      connectionStep = coreInstalled(coreId) ? 'core' : 'dependency';
      if (coreInstalled(coreId)) advanceConnection();
      error = null;
    });
  }

  void chooseProtocol(ProtocolDefinition protocol) {
    final candidates = candidateEngines(protocol.id);
    if (candidates.isEmpty) return;
    setState(() {
      selectedProtocol = protocol.id;
      selectedCore = null;
      connectionErrors = {};
      advancedGroups.clear();
      connectionStep = 'core';
    });
    if (candidates.length == 1) chooseCore(candidates.single);
    Timer(const Duration(milliseconds: 30), () {
      (web.document.querySelector('#field-name') as web.HTMLElement?)?.focus();
    });
  }

  Future<void> saveConnection() async {
    if (selectedCore == null || selectedProtocol == null || !canEdit) return;
    if (!store.supports(selectedCore, selectedProtocol)) {
      setState(() => error = t('protocol.unavailable'));
      return;
    }
    final definition = store.definition(selectedCore!, selectedProtocol!);
    final name = draft['name']?.trim() ?? '';
    final port = int.tryParse(draft['port'] ?? '');
    if (name.isEmpty ||
        (definition.usesPort && (port == null || port < 1 || port > 65535))) {
      setState(
        () => error = t(
          name.isEmpty ? 'common.invalidName' : 'common.invalidPort',
        ),
      );
      return;
    }
    if (definition.validateFields(draft).isNotEmpty) {
      setState(() => error = t('common.required'));
      return;
    }
    final old = store.connections.where((c) => c.id == editingId).firstOrNull;
    final value = Connection(
      id: editingId ?? '',
      name: name,
      coreId: selectedCore!,
      protocolId: selectedProtocol!,
      port: port,
      instanceId:
          old?.instanceId ?? store.instanceIds[selectedCore] ?? 'primary',
      enabled: old?.enabled ?? true,
      settings: {
        for (final f in definition.activeFields(draft))
          f.id: draft[f.id] ?? f.initialValue(draft),
      },
    );
    final id = editingId;
    await changePanel(
      () => api.saveConnection(draftRevision, value, id: id),
      dismiss: true,
      onError: (e) {
        if (e.fields.isNotEmpty)
          setState(() {
            connectionErrors = e.fields;
            connectionStep = 'parameters';
          });
      },
    );
  }

  void editRecipient([Recipient? recipient]) {
    if (!canInspect) return;
    editingId = recipient?.id;
    draft = {'name': recipient?.name ?? ''};
    grants = {...?recipient?.connectionIds};
    openModal('recipient');
  }

  Future<void> saveRecipient() async {
    final name = draft['name']?.trim() ?? '';
    if (name.isEmpty) {
      setState(() => error = t('common.invalidName'));
      return;
    }
    final old = store.recipients.where((u) => u.id == editingId).firstOrNull;
    final value = Recipient(
      id: editingId ?? '',
      name: name,
      enabled: old?.enabled ?? true,
      connectionIds: grants.toList(),
    );
    final id = editingId;
    await changePanel(
      () => api.saveRecipient(draftRevision, value, id: id),
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
    await changePanel(() => api.delete(draftRevision, kind, id), dismiss: true);
  }

  @override
  Component build(BuildContext context) => div([
    sidebar(),
    div(
      [
        el('header', [
          div([
            txt(t('app.name'), classes: 'compact-brand'),
            icon('server'),
            txt(store.serverName, classes: 'server-name'),
            txt('/', classes: 'breadcrumb-slash'),
            txt(t('nav.$page')),
          ], classes: 'breadcrumb'),
          div([
            span([], classes: 'status-dot'),
            txt(
              t(
                dataBusy
                    ? 'data.applying'
                    : panelData == null
                    ? 'runtime.loading'
                    : dataError != null
                    ? 'runtime.offline'
                    : 'runtime.connectedLabel',
              ),
            ),
          ], classes: 'demo-badge'),
        ], classes: 'topbar'),
        el('main', [
          if (panelData?.errorCode != null)
            div([
              icon('info'),
              Component.text(runtimeMessage(panelData!.errorCode!)),
            ], classes: 'notice'),
          if (page == 'connections')
            panelData == null
                ? emptyState(
                    'server',
                    t(
                      dataError == null ? 'runtime.loading' : 'runtime.offline',
                    ),
                  )
                : connectionsPage(),
          if (page == 'users')
            panelData == null
                ? emptyState(
                    'users',
                    t(
                      dataError == null ? 'runtime.loading' : 'runtime.offline',
                    ),
                  )
                : usersPage(),
          if (page == 'overview') overviewPage(),
          if (page == 'core') corePage(),
          if (page == 'logs') logsPage(),
          if (page == 'settings') settingsPage(),
          el('footer', [
            txt('${t('app.name')} / $appVersion'),
          ], classes: 'page-footer'),
        ], classes: 'main-content ${page == 'logs' ? 'logs-layout' : ''}'),
      ],
      classes: 'workspace',
      attributes: {if (modal != null) 'inert': ''},
    ),
    if (modal != null) modalView(),
    if (toast != null)
      div(
        [
          icon('check'),
          Component.text(toast!),
          iconButton(
            'close',
            t('common.close'),
            () => setState(() => toast = null),
          ),
        ],
        classes: 'toast',
        attributes: {'role': 'status', 'aria-live': 'polite'},
      ),
  ], classes: 'app-shell');

  Component sidebar() => el(
    'aside',
    [
      div([
        div([
          el(
            'svg',
            [
              el('path', [], attributes: {'d': 'M5 18 12 5l7 13M9 18l3-6 3 6'}),
            ],
            attributes: {
              'viewBox': '0 0 24 24',
              'fill': 'none',
              'stroke': 'currentColor',
              'stroke-width': '2',
              'stroke-linecap': 'round',
              'stroke-linejoin': 'round',
              'aria-hidden': 'true',
            },
          ),
        ], classes: 'brand-mark'),
        div([
          el('strong', [Component.text(t('app.name'))]),
        ], classes: 'brand-text'),
      ], classes: 'brand'),
      div([
        txt(t('nav.workspace'), classes: 'nav-label'),
        for (final key in ['overview', 'connections', 'users']) navItem(key),
        txt(t('nav.system'), classes: 'nav-label second-label'),
        for (final key in ['core', 'logs', 'settings']) navItem(key),
      ], classes: 'navigation'),
      div([
        panelUpdateCard(),
        div([
          txt(component.owner.username ?? '', classes: 'owner-name'),
          iconButton(
            'logout',
            t('auth.signOut'),
            () => unawaited(signOut()),
            disabled: ownerBusy,
          ),
        ], classes: 'owner'),
      ], classes: 'sidebar-bottom'),
    ],
    classes: 'sidebar',
    attributes: {if (modal != null) 'inert': ''},
  );

  Component navItem(String key) => button(
    [
      icon(key == 'overview' ? 'grid' : key),
      txt(t('nav.$key')),
      if (key == 'connections')
        txt('${store.connections.length}', classes: 'nav-count'),
    ],
    classes: 'nav-item ${page == key ? 'selected' : ''}',
    type: ButtonType.button,
    onClick: () => navigate(key),
    attributes: {
      'aria-label': t('nav.$key'),
      'title': t('nav.$key'),
      if (page == key) 'aria-current': 'page',
    },
  );

  Component heading(String key, {Component? trailing}) => div([
    div([
      h1([Component.text(t('$key.title'))]),
    ]),
    if (trailing != null) trailing,
  ], classes: 'page-heading');

  Component stat(String label, String value, String glyph, String detail) =>
      div([
        div([
          txt(label, classes: 'stat-label'),
          icon(glyph),
        ], classes: 'stat-top'),
        div([txt(value, classes: 'stat-value')], classes: 'stat-bottom'),
      ], classes: 'stat-card');

  Component statistics() => div([
    stat(
      t('connections.count'),
      '${store.connections.length}',
      'connections',
      t('connections.configured'),
    ),
    stat(
      t('connections.activeCount'),
      '${store.activeConnections}',
      'bolt',
      'mihomo',
    ),
    stat(
      t('users.count'),
      '${store.activeRecipients}',
      'users',
      t('users.active'),
    ),
  ], classes: 'stats-grid');

  Component connectionsPage() => div([
    heading(
      'connections',
      trailing: action(
        t('connections.add'),
        newConnection,
        disabled: !canInspect,
        glyph: 'plus',
        classes: 'button primary',
      ),
    ),
    statistics(),
    div([
      div([
        div([
          for (final f in ['all', 'active', 'disabled'])
            button(
              [
                Component.text(
                  t(f == 'all' ? 'connections.all' : 'connections.$f'),
                ),
                if (f == 'all')
                  txt('${store.connections.length}', classes: 'tab-count'),
              ],
              classes: 'tab ${filter == f ? 'active' : ''}',
              onClick: () => setState(() => filter = f),
              type: ButtonType.button,
            ),
        ], classes: 'tabs'),
        div([
          icon('search'),
          input<String>(
            value: search,
            onInput: (v) => setState(() => search = v),
            attributes: {
              'placeholder': t('connections.search'),
              'aria-label': t('connections.search'),
            },
          ),
        ], classes: 'search'),
      ], classes: 'table-toolbar'),
      connectionTable(
        store.connections
            .where(
              (c) =>
                  (filter == 'all' || c.enabled == (filter == 'active')) &&
                  '${c.name} ${c.protocolId} ${c.port}'.toLowerCase().contains(
                    search.toLowerCase(),
                  ),
            )
            .toList(),
      ),
      div([
        span([
          span([], classes: 'status-dot'),
          Component.text(runtimeStatus),
        ], classes: 'table-summary'),
        txt(store.serverName, classes: 'mono muted'),
      ], classes: 'table-footer'),
    ], classes: 'panel connection-panel'),
  ]);

  Component connectionTable(List<Connection> list) {
    if (list.isEmpty)
      return emptyState(
        'connections',
        t('connections.empty'),
        t('connections.emptyHint'),
      );
    return div([
      el('table', [
        el('colgroup', [
          for (final width in [30, 16, 14, 20, 10, 10])
            el('col', [], attributes: {'style': 'width: $width%'}),
        ]),
        el('thead', [
          el('tr', [
            for (final k in [
              'name',
              'protocol',
              'transport',
              'status',
              'enabled',
            ])
              el('th', [Component.text(t('table.$k'))]),
            el('th', [
              span([Component.text(t('table.actions'))], classes: 'sr-only'),
            ]),
          ]),
        ]),
        el('tbody', [
          for (final c in list)
            el('tr', [
              el('td', [
                div([
                  div([
                    icon('connections'),
                  ], classes: 'connection-icon ${c.enabled ? '' : 'dim'}'),
                  div([
                    button(
                      [Component.text(c.name)],
                      classes: 'name-button',
                      onClick: () => newConnection(c),
                      type: ButtonType.button,
                    ),
                    txt(
                      c.port == null
                          ? '—'
                          : '${store.address}:${c.assignedPorts.firstOrNull ?? c.port}${c.assignedPorts.length > 1 ? ' (+${c.assignedPorts.length - 1})' : ''}',
                      classes: 'endpoint',
                    ),
                  ]),
                ], classes: 'connection-name'),
              ]),
              el('td', [
                txt(
                  store.protocol(c.protocolId).name,
                  classes: 'protocol-tag ${c.protocolId}',
                ),
                txt(coreName(c.coreId), classes: 'transport-note'),
              ]),
              el('td', [
                txt(
                  c.settings['transport'] ??
                      (['hysteria2', 'tuic'].contains(c.protocolId)
                          ? 'QUIC'
                          : c.settings['network'] ?? 'TCP'),
                  classes: 'mono table-value',
                ),
                if (c.settings['security'] != null)
                  txt(c.settings['security']!, classes: 'transport-note'),
              ]),
              el('td', [
                pill(
                  t(
                    dataBusy
                        ? 'data.applying'
                        : !coreInstalled(c.coreId)
                        ? 'core.missingStatus'
                        : !c.enabled
                        ? 'status.disabled'
                        : c.shareable && store.recipientsFor(c.id).isEmpty
                        ? 'status.unassigned'
                        : !store.deliveryReady
                        ? 'status.stopped'
                        : 'status.active',
                  ),
                  positive:
                      !dataBusy &&
                      c.enabled &&
                      coreInstalled(c.coreId) &&
                      store.deliveryReady &&
                      (!c.shareable || store.recipientsFor(c.id).isNotEmpty),
                ),
              ]),
              el('td', [
                enabledCheckbox(
                  c.enabled,
                  '${t(c.enabled ? 'common.disable' : 'common.enable')}: ${c.name}',
                  () => toggleConnection(c),
                  disabled: !canEdit,
                ),
              ]),
              el('td', [
                div([
                  iconButton(
                    'edit',
                    '${t('common.edit')}: ${c.name}',
                    () => newConnection(c),
                  ),
                  iconButton(
                    'trash',
                    '${t('common.delete')}: ${c.name}',
                    () => confirmDelete('connection', c.id, c.name),
                  ),
                ], classes: 'row-actions'),
              ]),
            ], key: ValueKey(c.id)),
        ]),
      ]),
    ], classes: 'table-scroll connections-table');
  }

  Component avatars(List<Recipient> users) => div(
    [
      for (var i = 0; i < users.take(3).length; i++)
        span(
          [Component.text(users[i].name.substring(0, 1))],
          classes: 'mini-avatar avatar-$i',
          attributes: {'title': users[i].name},
        ),
      if (users.length > 3)
        txt('+${users.length - 3}', classes: 'avatar-extra'),
      if (users.isEmpty) txt('—', classes: 'muted'),
    ],
    classes: 'avatar-stack',
    attributes: {
      'aria-label': users.isEmpty
          ? t('common.noUsers')
          : users.map((u) => u.name).join(', '),
    },
  );

  Component usersPage() => div([
    heading(
      'users',
      trailing: action(
        t('users.add'),
        editRecipient,
        disabled: !canInspect,
        glyph: 'plus',
        classes: 'button primary',
      ),
    ),
    if (store.recipients.isEmpty)
      emptyState('users', t('users.none'))
    else
      div([
        el(
          'table',
          [
            el('colgroup', [
              for (final width in [28, 40, 12, 20])
                el('col', [], attributes: {'style': 'width: $width%'}),
            ]),
            el('thead', [
              el('tr', [
                for (final key in ['recipient', 'access', 'enabled', 'actions'])
                  el('th', [Component.text(t('table.$key'))]),
              ]),
            ]),
            el('tbody', [
              for (final user in store.recipients)
                el('tr', [
                  el('td', [
                    div([
                      div([
                        Component.text(
                          String.fromCharCode(user.name.runes.first),
                        ),
                      ], classes: 'user-avatar'),
                      button(
                        [Component.text(user.name)],
                        classes: 'name-button',
                        type: ButtonType.button,
                        onClick: () => editRecipient(user),
                      ),
                    ], classes: 'user-name'),
                  ]),
                  el('td', [
                    div([
                      for (final c in store.connections.where(
                        (c) => user.connectionIds.contains(c.id),
                      ))
                        span(
                          [
                            span(
                              [],
                              classes:
                                  'status-dot ${c.enabled && user.enabled ? '' : 'off'}',
                            ),
                            span([
                              Component.text(c.name),
                            ], classes: 'access-name'),
                          ],
                          classes: 'access-tag',
                          attributes: {
                            'title': user.connectionPorts[c.id] == null
                                ? c.name
                                : '${c.name} · :${user.connectionPorts[c.id]}',
                          },
                        ),
                      if (user.connectionIds.isEmpty)
                        txt('—', classes: 'muted'),
                    ], classes: 'access-list'),
                  ]),
                  el('td', [
                    enabledCheckbox(
                      user.enabled,
                      '${t(user.enabled ? 'common.disable' : 'common.enable')}: ${user.name}',
                      () => toggleRecipient(user),
                      disabled: !canEdit,
                    ),
                  ]),
                  el('td', [
                    div([
                      action(
                        t('users.subscription'),
                        () {
                          unawaited(openSharing(user));
                        },
                        glyph: 'link',
                        classes: 'button compact',
                        disabled: !user.enabled,
                      ),
                      iconButton(
                        'edit',
                        '${t('common.edit')}: ${user.name}',
                        () => editRecipient(user),
                      ),
                      iconButton(
                        'trash',
                        '${t('common.delete')}: ${user.name}',
                        () => confirmDelete('recipient', user.id, user.name),
                      ),
                    ], classes: 'row-actions'),
                  ]),
                ], key: ValueKey(user.id)),
            ]),
          ],
          attributes: {'aria-label': t('users.title')},
        ),
      ], classes: 'table-scroll users-table'),
  ]);

  String bytes(int? value) {
    if (value == null) return '—';
    return value >= 1000000000
        ? '${(value / 1000000000).toStringAsFixed(1)} ${t('system.gb')}'
        : '${(value / 1000000).toStringAsFixed(0)} ${t('system.mb')}';
  }

  Component metric(String title, String value, String detail) => div([
    txt(t(title), classes: 'muted'),
    txt(value, classes: 'metric-value'),
    txt(detail, classes: 'muted small'),
  ], classes: 'panel hardware-metric');
  Component overviewPage() {
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

  String rate(double? value) {
    if (value == null) return '—';
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(2)} MB/s';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)} KB/s';
    return '${value.toStringAsFixed(0)} B/s';
  }

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

  Component statusRow(
    String title,
    String value,
    String description,
    bool ready,
  ) => div([
    div([txt(t(title)), txt(t(description), classes: 'muted small')]),
    pill(value, positive: ready),
  ], classes: 'system-status-row');

  Component repositoryLink(String core) => el(
    'a',
    [icon('github')],
    classes: 'icon-button repository-link',
    attributes: {
      'href': 'https://github.com/${coreRepositories[core]}',
      'target': '_blank',
      'rel': 'noopener noreferrer',
      'aria-label': 'GitHub: ${coreName(core)}',
      'title': 'GitHub: ${coreName(core)}',
    },
  );

  Component corePage() => div([
    heading('core'),
    maintenanceStatus(),
    for (final descriptor in coreCatalog) engineCard(descriptor),
  ], classes: 'core-list');

  Component engineCard(CoreDescriptor descriptor) {
    final value = runtimes.where((r) => r.coreId == descriptor.id).firstOrNull;
    final installed = value?.binaryAvailable == true;
    final running = installed && value!.processState == CoreProcessState.active;
    final availableUpdate = engineUpdates[descriptor.id]?.available == true;
    final busy = dataBusy || runtimeBusy || maintenanceBusy || dependencyBusy;
    final status = !installed
        ? t('core.notInstalled')
        : t('runtime.state.${value!.processState.name}');
    return div([
      div([
        div([icon('core')], classes: 'core-large-icon'),
        h2([Component.text(descriptor.name)]),
        repositoryLink(descriptor.id),
        pill(status, positive: running),
      ], classes: 'core-header'),
      div([
        for (final fact in [
          (t('core.version'), value?.version ?? '—'),
          (
            t('core.service'),
            value?.service ?? 'sky-ui-${descriptor.id}.service',
          ),
          (
            t('runtime.controller'),
            installed
                ? t(
                    value!.controllerReady
                        ? 'runtime.ready'
                        : 'runtime.notReady',
                  )
                : '—',
          ),
          (
            t('core.memory'),
            value?.memoryBytes == null
                ? '—'
                : '${(value!.memoryBytes! / 1000000).toStringAsFixed(1)} MB',
          ),
        ])
          div([
            txt(fact.$1, classes: 'muted small'),
            txt(fact.$2, classes: 'mono'),
          ], classes: 'core-fact'),
      ], classes: 'core-facts'),
      div(
        [
          if (actionCore == descriptor.id && coreActionFeedback != null)
            Component.text(coreActionFeedback!)
          else if (installed && value?.error != null)
            Component.text(runtimeMessage(value!.error!.code)),
        ],
        classes: 'runtime-notice',
        attributes: {'role': 'status'},
      ),
      div([
        if (installed) ...[
          action(
            t(running ? 'core.stop' : 'core.start'),
            () => unawaited(
              runCoreAction(
                running ? CoreOperation.stop : CoreOperation.start,
                instanceId: value!.instanceId,
              ),
            ),
            glyph: 'power',
            disabled: busy || value?.platformSupported != true,
          ),
          action(
            t('core.restart'),
            () => unawaited(
              runCoreAction(
                CoreOperation.restart,
                instanceId: value!.instanceId,
              ),
            ),
            glyph: 'refresh',
            disabled: busy || value?.platformSupported != true,
          ),
        ],
        action(
          t(installed ? 'core.update' : 'core.install'),
          () => unawaited(prepareCoreUpdate(descriptor.id)),
          glyph: 'down',
          disabled: busy || maintenance?.available != true || !availableUpdate,
        ),
        if (installed)
          action(
            t('core.remove'),
            () {
              maintenanceCore = descriptor.id;
              openModal('coreRemove');
            },
            glyph: 'trash',
            classes: 'button danger',
            disabled: busy || maintenance?.available != true,
          ),
      ], classes: 'core-actions'),
    ], classes: 'panel core-panel');
  }

  String level(String value) => switch (value.toLowerCase()) {
    'warn' => 'warning',
    'panic' => 'fatal',
    _ => value.toLowerCase(),
  };
  Component logsPage() {
    final entries = runtimeLogs
        .where((entry) => selectedLogLevels.contains(level(entry.level)))
        .toList();
    scheduleLogTail();
    return div([
      heading(
        'logs',
        trailing: div([
          txt(
            t(logsLive ? 'logs.live' : 'logs.reconnecting'),
            classes: 'muted small',
          ),
          select(
            [
              for (final core in runtimes)
                option(
                  [Component.text(core.name)],
                  value: core.instanceId,
                  selected: selectedLogInstance == core.instanceId,
                ),
            ],
            value: selectedLogInstance,
            onChange: (values) {
              setState(() {
                runtimeGeneration++;
                selectedLogInstance = values.first;
                runtimeLogs = [];
                followingLogs = true;
              });
              connectLogs();
              unawaited(refreshRuntime());
            },
          ),
          action(
            t('logs.clear'),
            () => openModal('clearLogs'),
            glyph: 'trash',
            disabled: runtimeBusy || runtimeLogs.isEmpty || !runtimeOnline,
          ),
        ], classes: 'log-actions'),
      ),
      div([
        div([
          label([
            input<bool>(
              type: InputType.checkbox,
              checked: selectedLogLevels.length == 5,
              onChange: (checked) => setState(() {
                selectedLogLevels.clear();
                if (checked)
                  selectedLogLevels.addAll([
                    'debug',
                    'info',
                    'warning',
                    'error',
                    'fatal',
                  ]);
                followingLogs = true;
              }),
            ),
            txt(t('logs.all')),
          ], classes: 'log-level-option'),
          for (final entry in [
            ('debug', 'DEBUG'),
            ('info', 'INFO'),
            ('warning', 'WARN'),
            ('error', 'ERROR'),
            ('fatal', 'FATAL'),
          ])
            label([
              input<bool>(
                type: InputType.checkbox,
                checked: selectedLogLevels.contains(entry.$1),
                onChange: (checked) => setState(() {
                  if (checked) {
                    selectedLogLevels.add(entry.$1);
                  } else {
                    selectedLogLevels.remove(entry.$1);
                  }
                  followingLogs = true;
                }),
              ),
              txt(entry.$2),
            ], classes: 'log-level-option'),
        ], classes: 'log-level-filters'),
        action(
          t('logs.latest'),
          () => setState(() => followingLogs = true),
          glyph: 'down',
          disabled: followingLogs,
        ),
      ], classes: 'log-toolbar'),
      div(
        [
          if (entries.isEmpty)
            p([
              Component.text(
                t(runtimeLogs.isEmpty ? 'logs.empty' : 'logs.noMatches'),
              ),
            ], classes: 'muted log-empty'),
          for (final entry in entries)
            div([
              txt(
                '${entry.time.toLocal().hour.toString().padLeft(2, '0')}:${entry.time.toLocal().minute.toString().padLeft(2, '0')}:${entry.time.toLocal().second.toString().padLeft(2, '0')}',
                classes: 'mono log-time',
              ),
              txt(
                entry.level.toUpperCase(),
                classes: 'log-level level-${level(entry.level)}',
              ),
              txt(
                entry.source == 'panel'
                    ? runtimeMessage(entry.message)
                    : entry.message,
                classes: 'log-message',
              ),
            ], classes: 'log-row'),
        ],
        classes: 'panel log-panel runtime-log',
        events: {
          'scroll': (event) {
            final target = event.currentTarget as web.HTMLElement;
            final follows =
                target.scrollHeight - target.scrollTop - target.clientHeight <
                48;
            if (followingLogs != follows)
              setState(() => followingLogs = follows);
          },
        },
      ),
    ], classes: 'logs-page');
  }

  Component eventList(List<CoreLogEntry> events) => div([
    if (events.isEmpty) p([Component.text(t('logs.empty'))], classes: 'muted'),
    for (final event in events)
      div([
        txt(
          '${event.time.toLocal().hour.toString().padLeft(2, '0')}:${event.time.toLocal().minute.toString().padLeft(2, '0')}',
          classes: 'mono log-time',
        ),
        txt(event.level.toUpperCase(), classes: 'log-level'),
        Component.text(
          event.source == 'panel'
              ? runtimeMessage(event.message)
              : event.message,
        ),
      ], classes: 'log-row'),
  ], classes: 'event-list');

  Component settingsPage() => div([
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
              settingsRevision ??= panelData?.revision;
              editedServerName = v;
            },
            attributes: {'maxlength': '80'},
          ),
        ]),
        label([
          Component.text(t('settings.address')),
          input<String>(
            value: editedAddress ?? store.address,
            onInput: (v) {
              settingsRevision ??= panelData?.revision;
              editedAddress = v;
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
        () async {
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
            setState(() {
              editedServerName = null;
              editedAddress = null;
              settingsRevision = null;
            });
          }
        },
        classes: 'button primary',
        disabled: !canEdit,
      ),
    ], classes: 'panel settings-panel'),
    div([
      h2([Component.text(t('admin.title'))]),

      div([
        div([
          txt(t('admin.username')),
          pill(component.owner.username ?? ''),
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
          revokeSessionId = null;
          openModal('revokeSession');
        }, disabled: ownerBusy || ownerSessions.length < 2),
      ], classes: 'setting-row'),
      sessionList(),
    ], classes: 'panel settings-panel'),
    div([
      h2([Component.text(t('settings.system'))]),
      plannedSetting('settings.domain', 'common.edit'),
      plannedSetting('settings.dns', 'settings.configure'),
      plannedSetting('settings.logging', 'settings.configure'),
    ], classes: 'panel settings-panel'),
  ]);

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
        setState(() {
          maintenance = value;
          maintenanceJob = value.job;
          panelUpdateReconnecting = false;
        });
    } on ApiClientException {
      // The worker briefly stops the API. Keep the durable job visible until it returns.
      if (mounted &&
          maintenanceJob?.action == 'panel-update' &&
          maintenanceBusy)
        setState(() => panelUpdateReconnecting = true);
    } finally {
      maintenanceLoading = false;
    }
  }

  Future<void> refreshPanelUpdate({bool refresh = false}) async {
    if (panelUpdateLoading) return;
    setState(() {
      panelUpdateLoading = true;
      if (refresh) panelUpdateManualChecked = false;
    });
    try {
      final value = await api.panelUpdate(refresh: refresh);
      if (mounted)
        setState(() {
          panelUpdateInfo = value;
          panelUpdateError = null;
          if (refresh) panelUpdateManualChecked = true;
        });
    } on ApiClientException catch (e) {
      if (mounted) setState(() => panelUpdateError = e.code);
    } finally {
      panelUpdateChecked = DateTime.now();
      if (mounted) setState(() => panelUpdateLoading = false);
    }
  }

  Component panelUpdateCard() {
    final updating =
        maintenanceJob?.action == 'panel-update' && maintenanceBusy;
    final failed =
        maintenanceJob?.action == 'panel-update' &&
        maintenanceJob?.status == 'failed';
    return PanelUpdateCard(
      info: panelUpdateInfo,
      job: maintenanceJob?.action == 'panel-update' ? maintenanceJob : null,
      reconnecting: panelUpdateReconnecting,
      onDetails: () => openModal('panelUpdateDetails'),
      checking: panelUpdateLoading,
      updating: updating,
      busy: maintenanceBusy,
      checkedManually: panelUpdateManualChecked,
      checkError: panelUpdateError == null
          ? null
          : t('panelUpdate.checkFailed'),
      updateError: failed && !panelUpdateManualChecked
          ? runtimeMessage(maintenanceJob!.error ?? 'panel_update_failed')
          : null,
      updateEnabled: maintenance?.available == true,
      onCheck: () => refreshPanelUpdate(refresh: true),
      onUpdate: () {
        panelUpdateTarget = panelUpdateInfo?.tag;
        panelUpdateManualChecked = false;
        openModal('panelUpdate');
      },
    );
  }

  Future<void> refreshCoreUpdates() async {
    if (updatesLoading) return;
    updatesLoading = true;
    try {
      final values = await Future.wait(
        coreCatalog.map((c) async {
          try {
            return await api.updates(c.id);
          } on ApiClientException {
            return null;
          }
        }),
      );
      if (mounted)
        setState(() {
          engineUpdates.clear();
          for (final value in values.whereType<CoreUpdateInfo>()) {
            engineUpdates[value.coreId] = value;
          }
          coreUpdates = engineUpdates['mihomo'];
          updatesError = null;
        });
    } on ApiClientException catch (e) {
      if (mounted)
        setState(() {
          coreUpdates = null;
          updatesError = e.code;
        });
    } finally {
      if (mounted) setState(() => updatesLoading = false);
    }
  }

  Future<void> prepareCoreUpdate([String core = 'mihomo']) async {
    await refreshCoreUpdates();
    final value = engineUpdates[core];
    if (!mounted || value?.available != true || updatesError != null) return;
    maintenanceCore = core;
    updateNotes = value;
    updateTag = updateNotes!.versions.first;
    openModal(coreInstalled(core) ? 'coreUpdate' : 'coreInstall');
  }

  Future<void> submitMaintenance(String action) async {
    if (maintenanceBusy) return;
    setState(() => maintenanceSubmitting = true);
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
        setState(() {
          maintenanceJob = job;
          if (action == 'panel-update') panelUpdateReloadId = job.id;
        });
    } on ApiClientException catch (e) {
      if (mounted) {
        setState(() => error = runtimeMessage(e.code));
        return;
      }
    } finally {
      if (mounted) setState(() => maintenanceSubmitting = false);
    }
    if (mounted) closeModal();
  }

  Component maintenanceStatus() {
    final job = maintenanceJob;
    return div(
      [
        if (job != null)
          txt(
            job.status == 'failed'
                ? runtimeMessage(job.error ?? 'maintenance_failed')
                : t('maintenance.status.${job.status}'),
            classes: job.status == 'failed' ? 'form-error' : 'muted small',
          ),
      ],
      attributes: {'role': 'status', 'aria-live': 'polite'},
    );
  }

  Component backupPanel() => div([
    div([
      h2([Component.text(t('maintenance.backups'))]),
      action(
        t('maintenance.create'),
        () => openModal('backup'),
        glyph: 'plus',
        disabled: maintenance?.available != true || maintenanceBusy,
      ),
    ], classes: 'maintenance-heading'),
    maintenanceStatus(),
    if (maintenance?.available != true) pill(t('feature.unavailable')),
    if (maintenance?.available == true && maintenance!.backups.isEmpty)
      p([Component.text(t('maintenance.empty'))], classes: 'muted small'),
    for (final backup in maintenance?.backups ?? <BackupInfo>[])
      div([
        div([
          txt(
            DateTime.tryParse(
                  backup.created,
                )?.toLocal().toString().substring(0, 19) ??
                backup.created,
          ),
          txt(
            'Sky UI ${backup.version} · ${backup.size < 1000000 ? '${(backup.size / 1000).toStringAsFixed(1)} KB' : '${(backup.size / 1000000).toStringAsFixed(1)} MB'}',
            classes: 'muted small',
          ),
        ]),
        div([
          a(
            [Component.text(t('maintenance.download'))],
            href: '/api/v1/backups/${backup.id}/download',
            classes: 'button',
            attributes: {'download': 'sky-ui-${backup.id}.tar.gz'},
          ),
          action(t('maintenance.restore'), () {
            maintenanceBackupId = backup.id;
            openModal('restore');
          }, disabled: maintenanceBusy || backup.version != appVersion),
        ], classes: 'core-actions'),
      ], classes: 'setting-row'),
    p([Component.text(t('maintenance.secrets'))], classes: 'muted small'),
  ], classes: 'panel settings-panel');

  Future<void> refreshOwnerSessions() async {
    if (ownerSessionsLoading || ownerBusy) return;
    ownerSessionsLoading = true;
    try {
      final values = await api.ownerSessions();
      if (mounted) setState(() => ownerSessions = values);
    } on ApiClientException catch (e) {
      if (mounted && e.code != 'auth_required') notify(runtimeMessage(e.code));
    } finally {
      ownerSessionsLoading = false;
    }
  }

  Future<void> signOut() async {
    if (ownerBusy) return;
    setState(() => ownerBusy = true);
    try {
      await api.logout();
      if (mounted) component.onSignedOut();
    } on ApiClientException catch (e) {
      if (mounted) notify(runtimeMessage(e.code));
    } finally {
      if (mounted) setState(() => ownerBusy = false);
    }
  }

  void editOwner(bool password) {
    ownerDraft.clear();
    ownerDraft['username'] = component.owner.username ?? '';
    openModal(password ? 'ownerPassword' : 'ownerName');
  }

  Component ownerField(
    String id,
    String labelKey, {
    bool secret = false,
    String? autocomplete,
  }) => label([
    txt(t(labelKey)),
    input<String>(
      value: ownerDraft[id] ?? '',
      type: secret ? InputType.password : InputType.text,
      disabled: ownerBusy,
      onInput: (v) => ownerDraft[id] = v,
      attributes: {
        'autocomplete': autocomplete ?? 'off',
        'maxlength': secret ? '72' : '32',
      },
    ),
  ]);
  Component ownerForm() => div([
    if (modal == 'ownerName')
      ownerField('username', 'admin.username', autocomplete: 'username'),
    ownerField(
      'currentPassword',
      'admin.currentPassword',
      secret: true,
      autocomplete: 'current-password',
    ),
    if (modal == 'ownerPassword') ...[
      ownerField(
        'password',
        'admin.newPassword',
        secret: true,
        autocomplete: 'new-password',
      ),
      ownerField(
        'confirmation',
        'admin.confirmPassword',
        secret: true,
        autocomplete: 'new-password',
      ),
      p([Component.text(t('admin.passwordHint'))], classes: 'muted small'),
    ],
    p([Component.text(t('admin.rotationHint'))], classes: 'muted small'),
  ], classes: 'owner-form');
  Future<void> saveOwner() async {
    if (ownerBusy) return;
    if ((ownerDraft['currentPassword'] ?? '').isEmpty) {
      setState(() => error = t('common.required'));
      return;
    }
    if (modal == 'ownerPassword' &&
        ownerDraft['password'] != ownerDraft['confirmation']) {
      setState(() => error = t('admin.passwordMismatch'));
      return;
    }
    final payload = <String, Object?>{
      'currentPassword': ownerDraft['currentPassword'],
      if (modal == 'ownerName') 'username': ownerDraft['username']?.trim(),
      if (modal == 'ownerPassword') 'password': ownerDraft['password'] ?? '',
    };
    setState(() => ownerBusy = true);
    try {
      final owner = await api.changeOwner(payload);
      if (mounted) {
        ownerDraft.clear();
        component.onOwnerChanged(owner);
      }
    } on ApiClientException catch (e) {
      if (mounted) setState(() => error = runtimeMessage(e.code));
    } finally {
      if (mounted) setState(() => ownerBusy = false);
    }
  }

  Future<void> revokeOwnerSessions() async {
    if (ownerBusy) return;
    final id = revokeSessionId;
    setState(() => ownerBusy = true);
    try {
      if (id == null) {
        await api.revokeOtherSessions();
      } else {
        await api.revokeSession(id);
      }
      if (!mounted) return;
      if (id == component.owner.sessionId) {
        component.onSignedOut();
        return;
      }
      setState(() => ownerBusy = false);
      closeModal();
      await refreshOwnerSessions();
    } on ApiClientException catch (e) {
      if (mounted) setState(() => error = runtimeMessage(e.code));
    } finally {
      if (mounted) setState(() => ownerBusy = false);
    }
  }

  String sessionDevice(String ua) {
    final browser = ua.contains('Edg/')
        ? 'Edge'
        : ua.contains('Firefox/')
        ? 'Firefox'
        : ua.contains('Chrome/')
        ? 'Chrome'
        : ua.contains('Safari/')
        ? 'Safari'
        : ua.contains('Dart/') || ua.contains('Python')
        ? 'CLI'
        : 'Browser';
    final os = ua.contains('Windows')
        ? 'Windows'
        : ua.contains('Android')
        ? 'Android'
        : ua.contains('iPhone')
        ? 'iOS'
        : ua.contains('Mac OS')
        ? 'macOS'
        : ua.contains('Linux')
        ? 'Linux'
        : '';
    return os.isEmpty ? browser : '$browser · $os';
  }

  String sessionTime(DateTime date) {
    final value = date.toLocal();
    return '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
  }

  Component sessionList() => div([
    if (ownerSessions.isEmpty)
      p([Component.text(t('runtime.loading'))], classes: 'muted'),
    if (ownerSessions.isNotEmpty)
      el('table', [
        el('thead', [
          el('tr', [
            for (final key in [
              'admin.device',
              'admin.ip',
              'admin.lastSeen',
              'admin.actions',
            ])
              el('th', [Component.text(t(key))]),
          ]),
        ]),
        el('tbody', [
          for (final session in ownerSessions)
            el('tr', [
              el('td', [
                txt(sessionDevice(session.agent)),
                if (session.current)
                  txt(t('admin.currentSession'), classes: 'muted small'),
              ]),
              el('td', [txt(session.ip, classes: 'mono')]),
              el('td', [txt(sessionTime(session.lastSeen), classes: 'mono')]),
              el('td', [
                iconButton('logout', t('admin.revoke'), () {
                  revokeSessionId = session.id;
                  openModal('revokeSession');
                }, disabled: ownerBusy),
              ]),
            ]),
        ]),
      ], classes: 'session-table'),
  ], classes: 'session-container');

  Component plannedSetting(String title, String actionKey) => div([
    div([
      txt(t(title)),
      txt(t('feature.unavailable'), classes: 'availability-chip'),
    ], classes: 'setting-label'),
    action(t(actionKey), () {}, disabled: true),
  ], classes: 'setting-row');

  Component emptyState(String glyph, String title, [String? description]) =>
      div([
        icon(glyph),
        h3([Component.text(title)]),
        if (description != null) p([Component.text(description)]),
      ], classes: 'empty-state');

  Component modalView() => div([
    div(
      [
        div([
          div([
            h2([
              Component.text(
                t(switch (modal) {
                  'connection' =>
                    editingId == null ? 'modal.new' : 'modal.edit',
                  'recipient' =>
                    editingId == null ? 'users.add' : 'common.edit',
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
                  'panelUpdate' => 'panelUpdate.title',
                  'panelUpdateDetails' => 'panelUpdate.details',
                  _ => 'modal.deleteTitle',
                }),
              ),
            ], id: 'modal-title'),
            if (modal == 'connection')
              div([
                for (final step in connectionSteps)
                  button(
                    [Component.text(t('builder.step.$step'))],
                    classes:
                        'step-button ${step == connectionStep
                            ? 'active'
                            : connectionSteps.indexOf(step) < connectionSteps.indexOf(connectionStep)
                            ? 'complete'
                            : ''}',
                    type: ButtonType.button,
                    disabled:
                        dataBusy ||
                        connectionSteps.indexOf(step) >
                            connectionSteps.indexOf(connectionStep) ||
                        editingId != null &&
                            (step == 'core' || step == 'protocol'),
                    onClick: () => setState(() {
                      connectionStep = step;
                      connectionErrors = {};
                      error = null;
                    }),
                  ),
              ], classes: 'steps builder-steps'),
          ]),
          iconButton(
            'close',
            t('common.close'),
            closeModal,
            classes: 'icon-button modal-close',
            disabled: dataBusy || clearingLogs || ownerBusy,
          ),
        ], classes: 'modal-header'),
        div([
          if (modal == 'connection') connectionForm(),
          if (modal == 'panelUpdateDetails')
            PanelUpdateDetails(
              job: maintenanceJob?.action == 'panel-update'
                  ? maintenanceJob
                  : null,
              info: panelUpdateInfo,
              checkError: panelUpdateError,
            ),
          if (modal == 'recipient') recipientForm(),
          if (modal == 'share') shareContent(),
          if (modal == 'clearLogs') p([Component.text(t('logs.clearHint'))]),
          if (modal == 'backup')
            p([Component.text(t('maintenance.backupHint'))]),
          if (modal == 'restore')
            p([Component.text(t('maintenance.restoreHint'))]),
          if (modal == 'panelUpdate') ...[
            txt(
              'v${panelUpdateInfo?.currentVersion ?? appVersion} → ${panelUpdateTarget ?? '—'}',
              classes: 'mono',
            ),
            p([Component.text(t('panelUpdate.hint'))]),
          ],
          if (modal == 'coreRemove') p([Component.text(t('core.removeHint'))]),
          if (modal == 'coreUpdate' || modal == 'coreInstall') ...[
            if (updateNotes == null && error == null)
              txt(t('maintenance.loading')),
            if (updateNotes != null) ...[
              label([
                Component.text(t('core.version')),
                select(
                  [
                    for (final tag in updateNotes!.versions)
                      option(
                        [Component.text(tag)],
                        value: tag,
                        selected: tag == updateTag,
                      ),
                  ],
                  value: updateTag,
                  onChange: (value) => setState(() => updateTag = value.first),
                ),
              ]),
              txt(
                '$maintenanceCore · ${runtimes.where((c) => c.coreId == maintenanceCore).firstOrNull?.version ?? '—'} → $updateTag',
                classes: 'mono',
              ),
              p([
                Component.text(
                  t(
                    modal == 'coreInstall'
                        ? 'core.installHint'
                        : 'maintenance.updateHint',
                  ),
                ),
              ]),
            ],
          ],
          if (modal == 'ownerName' || modal == 'ownerPassword') ownerForm(),
          if (modal == 'revokeSession')
            p([
              Component.text(
                t(
                  revokeSessionId == null
                      ? 'admin.revokeOthersHint'
                      : 'admin.revokeHint',
                ),
              ),
            ]),
          if (modal == 'delete')
            p([
              Component.text(t('modal.deleteHint', {'name': deleteName!})),
            ]),
          if (error != null)
            div(
              [icon('info'), Component.text(error!)],
              classes: 'form-error',
              attributes: {'role': 'alert'},
            ),
        ], classes: 'modal-body'),
        if (modal != 'share')
          div([
            if (modal == 'connection' &&
                connectionSteps.indexOf(connectionStep) > 0 &&
                editingId == null)
              action(
                t('common.back'),
                () => setState(() {
                  final previous = connectionSteps.indexOf(connectionStep) - 1;
                  if (previous >= 0) {
                    connectionStep = connectionSteps[previous];
                  }
                  connectionErrors = {};
                  error = null;
                }),
                classes: 'button ghost',
                disabled: dataBusy || clearingLogs || ownerBusy,
              ),
            div([
              action(
                t(
                  modal == 'panelUpdateDetails'
                      ? 'common.close'
                      : 'common.cancel',
                ),
                closeModal,
                disabled: dataBusy || clearingLogs || ownerBusy,
              ),
              if (modal == 'panelUpdateDetails')
                action(t('common.copy'), () async {
                  try {
                    await web.window.navigator.clipboard
                        .writeText(
                          const JsonEncoder.withIndent('  ').convert({
                            'currentVersion': panelUpdateInfo?.currentVersion,
                            'latestVersion': panelUpdateInfo?.latestVersion,
                            'checkError': panelUpdateError,
                            'job': maintenanceJob?.action == 'panel-update'
                                ? maintenanceJob?.toJson()
                                : null,
                          }),
                        )
                        .toDart;
                    notify(t('common.copied'));
                  } catch (_) {
                    notify(t('common.copyFailed'));
                  }
                }, glyph: 'copy'),
              if (modal == 'ownerName' || modal == 'ownerPassword')
                action(
                  t('common.save'),
                  () => unawaited(saveOwner()),
                  classes: 'button primary',
                  disabled: ownerBusy,
                ),
              if (modal == 'revokeSession')
                action(
                  t('admin.revoke'),
                  () => unawaited(revokeOwnerSessions()),
                  classes: 'button danger',
                  disabled: ownerBusy,
                ),
              if (modal == 'connection' &&
                  selectedCore != null &&
                  !{'core', 'protocol', 'dependency'}.contains(connectionStep))
                action(
                  t(
                    connectionStep == 'review'
                        ? (editingId == null ? 'common.create' : 'common.save')
                        : 'builder.next',
                  ),
                  connectionStep == 'review'
                      ? saveConnection
                      : () => setState(advanceConnection),
                  classes: 'button primary',
                  disabled:
                      (connectionStep == 'review' ? !canEdit : !canInspect) ||
                      !store.supports(selectedCore, selectedProtocol),
                ),
              if (modal == 'recipient')
                action(
                  t('common.save'),
                  saveRecipient,
                  disabled: !canEdit,
                  classes: 'button primary',
                ),
              if (modal == 'clearLogs')
                action(
                  t('logs.clear'),
                  () => unawaited(clearLogHistory()),
                  classes: 'button danger',
                  disabled: clearingLogs || runtimeBusy,
                ),
              if (modal == 'backup' ||
                  modal == 'restore' ||
                  modal == 'coreUpdate' ||
                  modal == 'coreInstall' ||
                  modal == 'coreRemove')
                action(
                  t(
                    modal == 'backup'
                        ? 'maintenance.create'
                        : modal == 'restore'
                        ? 'maintenance.restore'
                        : modal == 'coreRemove'
                        ? 'core.remove'
                        : modal == 'coreInstall'
                        ? 'core.install'
                        : 'core.update',
                  ),
                  () => unawaited(
                    submitMaintenance(
                      modal == 'backup'
                          ? 'backup'
                          : modal == 'restore'
                          ? 'restore'
                          : modal == 'coreRemove'
                          ? 'remove'
                          : modal == 'coreInstall'
                          ? 'install'
                          : 'update',
                    ),
                  ),
                  classes:
                      'button ${['restore', 'coreRemove'].contains(modal) ? 'danger' : 'primary'}',
                  disabled:
                      maintenanceBusy ||
                      (['coreUpdate', 'coreInstall'].contains(modal) &&
                          (updateNotes == null ||
                              !updateNotes!.versions.contains(updateTag))),
                ),
              if (modal == 'panelUpdate')
                action(
                  t('panelUpdate.update'),
                  () => unawaited(submitMaintenance('panel-update')),
                  classes: 'button primary',
                  disabled:
                      maintenanceBusy || panelUpdateInfo?.available != true,
                ),
              if (modal == 'delete')
                action(
                  t('common.delete'),
                  performDelete,
                  disabled: !canEdit,
                  classes: 'button danger',
                ),
            ], classes: 'modal-footer-actions'),
          ], classes: 'modal-footer'),
      ],
      classes: 'modal ${modal == 'connection' ? 'wide' : ''}',
      attributes: {
        'role': 'dialog',
        'aria-modal': 'true',
        'aria-labelledby': 'modal-title',
      },
    ),
  ], classes: 'modal-overlay');

  List<String> get connectionSteps {
    final definition = selectedCore != null && selectedProtocol != null
        ? store.definition(selectedCore!, selectedProtocol!)
        : null;
    return [
      'protocol',
      if (selectedProtocol == null ||
          candidateEngines(selectedProtocol!).length > 1)
        'core',
      if (selectedCore != null && !coreInstalled(selectedCore!)) 'dependency',
      if (definition == null ||
          definition.fields.any((f) => f.group == 'transport'))
        'transport',
      if (definition == null ||
          definition.fields.any((f) => f.group == 'security'))
        'security',
      'parameters',
      'review',
    ];
  }

  void advanceConnection() {
    if (selectedCore == null || selectedProtocol == null) return;
    final definition = store.definition(selectedCore!, selectedProtocol!);
    connectionErrors = {
      for (final f
          in definition
              .activeFields(draft)
              .where(
                (f) => connectionStep == 'parameters'
                    ? !isStepChoice(f, definition)
                    : f.group == connectionStep && isStepChoice(f, definition),
              ))
        if (f.validate(draft[f.id] ?? '', draft) case final String e) f.id: e,
    };
    if (connectionStep == 'parameters') {
      if ((draft['name'] ?? '').trim().isEmpty)
        connectionErrors['name'] = 'required';
      final port = int.tryParse(draft['port'] ?? '');
      if (definition.usesPort && (port == null || port < 1 || port > 65535))
        connectionErrors['port'] = 'range_invalid';
    }
    if (connectionErrors.isNotEmpty) return;
    final steps = connectionSteps;
    var index = connectionStep == 'core' && !steps.contains('core')
        ? 1
        : steps.indexOf(connectionStep) + 1;
    while (index < steps.length - 1) {
      final fields = definition
          .activeFields(draft)
          .where((f) => f.group == steps[index] && isStepChoice(f, definition))
          .toList();
      if (fields.isNotEmpty &&
          !fields.every((f) => !f.advanced && f.options.length == 1))
        break;
      if (steps[index] == 'parameters') break;
      index++;
    }
    connectionStep = steps[index.clamp(0, steps.length - 1)];
    error = null;
  }

  bool isStepChoice(ProtocolField field, ProtocolDefinition definition) => {
    definition.clientFieldBindings['transport'],
    definition.clientFieldBindings['security'],
    if (definition.id == 'hysteria2') 'native.obfs',
    if (definition.id == 'hysteria2') 'obfs',
  }.contains(field.id);

  Future<void> installDependency() async {
    if (dependencyBusy || selectedCore == null) return;
    final core = selectedCore!, protocol = selectedProtocol;
    final generation = ++dependencyGeneration;
    bool current() =>
        mounted &&
        generation == dependencyGeneration &&
        modal == 'connection' &&
        selectedCore == core &&
        selectedProtocol == protocol;
    setState(() {
      dependencyBusy = true;
      error = null;
      dependencyMessage = t('builder.installChecking');
    });
    try {
      final update = await api.updates(core);
      if (!current()) return;
      if (!update.available || update.versions.isEmpty)
        throw const ApiClientException('core_release_unverified');
      final job = await api.maintain(
        'install',
        core: core,
        tag: update.versions.first,
      );
      if (!current()) return;
      setState(() {
        maintenanceJob = job;
        dependencyJobId = job.id;
        dependencyReconnecting = false;
        dependencyMessage = t(
          core == 'amneziawg' ? 'builder.installingAwg' : 'builder.installing',
        );
      });
      final deadline = DateTime.now().add(const Duration(minutes: 12));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!current()) return;
        MaintenanceSnapshot status;
        try {
          status = await api.maintenance();
        } on ApiClientException catch (e) {
          if (e.code == 'auth_required') rethrow;
          if (current()) setState(() => dependencyReconnecting = true);
          continue; // The maintenance worker briefly stops the API while installing.
        }
        if (!current()) return;
        setState(() {
          maintenance = status;
          maintenanceJob = status.job;
          dependencyReconnecting = false;
        });
        if (status.job?.id != job.id || status.job!.busy) continue;
        if (status.job!.status != 'completed')
          throw ApiClientException(status.job!.error ?? 'maintenance_failed');
        final snapshots = await api.cores();
        final data = await api.panel();
        if (!current()) return;
        setState(() {
          runtimes = snapshots;
          panelData = data;
          store.apply(data);
          draftRevision = data.revision;
          dependencyMessage = null;
        });
        chooseCore(core);
        return;
      }
      throw const ApiClientException('maintenance_timeout');
    } on ApiClientException catch (e) {
      if (current()) setState(() => error = runtimeMessage(e.code));
    } finally {
      if (current()) setState(() => dependencyBusy = false);
    }
  }

  Component connectionForm() {
    if (connectionStep == 'protocol')
      return div([
        div([
          for (final protocol in productProtocols)
            productProtocolCard(protocol),
        ], classes: 'protocol-grid'),
      ]);
    if (connectionStep == 'core')
      return div([
        div([
          for (final id in candidateEngines(selectedProtocol!))
            button(
              [
                icon('core'),
                txt(coreName(id)),
                if (id == candidateEngines(selectedProtocol!).first)
                  txt(t('builder.recommended'), classes: 'recommended-badge'),
                txt(
                  t(
                    coreInstalled(id)
                        ? 'builder.engineInstalled'
                        : 'builder.engineRequired',
                  ),
                  classes: 'muted small',
                ),
              ],
              classes: 'protocol-option core-option',
              type: ButtonType.button,
              disabled: dataBusy || dependencyBusy,
              onClick: () => chooseCore(id),
            ),
        ], classes: 'protocol-grid core-grid'),
      ]);
    if (connectionStep == 'dependency')
      return div([
        h3([Component.text(coreName(selectedCore!))]),
        p([Component.text(t('builder.installRequired'))]),
        if (dependencyMessage != null) p([Component.text(dependencyMessage!)]),
        if (dependencyBusy ||
            (dependencyJobId != null &&
                maintenanceJob?.id == dependencyJobId) ||
            maintenanceJob?.core == selectedCore &&
                ['install', 'update'].contains(maintenanceJob?.action))
          CoreInstallProgress(
            core: selectedCore!,
            job:
                (dependencyJobId != null &&
                        maintenanceJob?.id == dependencyJobId) ||
                    maintenanceJob?.core == selectedCore
                ? maintenanceJob
                : null,
            busy: dependencyBusy || maintenanceJob?.busy == true,
            reconnecting: dependencyReconnecting,
          ),
        action(
          t(dependencyBusy ? 'builder.installing' : 'builder.installContinue'),
          () => coreInstalled(selectedCore!)
              ? setState(() => chooseCore(selectedCore!))
              : unawaited(installDependency()),
          classes: 'button primary',
          disabled: dependencyBusy || maintenanceBusy,
        ),
      ], classes: 'builder-content');
    final definition = store.definition(selectedCore!, selectedProtocol!);
    final fields = definition
        .activeFields(draft)
        .where(
          (f) => connectionStep == 'parameters'
              ? !isStepChoice(f, definition)
              : f.group == connectionStep && isStepChoice(f, definition),
        )
        .toList();
    return div([
      div([
        txt(coreName(selectedCore!), classes: 'protocol-tag'),
        txt(definition.name, classes: 'protocol-tag'),
        for (final id in ['transport', 'security'])
          if (draft[id]?.isNotEmpty == true)
            txt(draft[id]!, classes: 'protocol-tag'),
      ], classes: 'selected-protocol'),
      for (final restriction in definition.exportRestrictions.where(
        (r) => r.matches(definition.clientValues(draft)),
      ))
        p([
          Component.text(t(restriction.reasonKey)),
        ], classes: 'builder-notice'),
      if (connectionStep == 'review' && definition.deliveryHintKey != null)
        p([
          Component.text(t(definition.deliveryHintKey!)),
        ], classes: 'muted small'),
      if (connectionStep == 'review') ...[
        h3([
          Component.text(t('builder.review')),
        ], classes: 'form-section-title'),
        el('dl', [
          for (final entry in <String, String>{
            t('field.name'): draft['name'] ?? '',
            t('builder.address'): definition.usesPort
                ? '${store.address}:${draft['port']}'
                : store.address,
            for (final f
                in definition
                    .activeFields(draft)
                    .where(
                      (f) => !f.advanced && (draft[f.id] ?? '').isNotEmpty,
                    ))
              t(f.labelKey): f.secret ? '••••••••' : draft[f.id]!,
          }.entries)
            div([
              el('dt', [Component.text(entry.key)]),
              el('dd', [Component.text(entry.value)]),
            ], classes: 'review-row'),
        ], classes: 'connection-review'),
        p([
          Component.text(
            t(
              !definition.shareable
                  ? 'builder.systemInput'
                  : definition.isolatedBindings
                  ? 'builder.isolatedPorts'
                  : 'builder.credentialsAuto',
            ),
          ),
        ], classes: 'muted small'),
      ] else ...[
        if (connectionStep == 'parameters') ...[
          h3([
            Component.text(t('modal.general')),
          ], classes: 'form-section-title'),
          div([
            field(const ProtocolField('name', required: true, maxLength: 80)),
            if (definition.usesPort)
              field(
                const ProtocolField(
                  'port',
                  kind: 'integer',
                  minimum: 1,
                  maximum: 65535,
                  required: true,
                ),
              ),
          ], classes: 'form-grid'),
        ],
        for (final f in fields.where((f) => f.kind == 'choice' && !f.advanced))
          field(f),
        div([
          for (final f in fields.where(
            (f) => f.kind != 'choice' && !f.advanced,
          ))
            field(f),
        ], classes: 'form-grid'),
        if (fields.any((f) => f.advanced)) ...[
          action(
            t('builder.advanced'),
            () => setState(() {
              if (!advancedGroups.add(connectionStep))
                advancedGroups.remove(connectionStep);
            }),
            glyph: 'chevron',
            classes: 'button ghost advanced-toggle',
          ),
          if (advancedGroups.contains(connectionStep))
            div([
              for (final f in fields.where((f) => f.advanced)) field(f),
            ], classes: 'form-grid'),
        ],
      ],
    ], classes: 'builder-content');
  }

  Component protocolCard(ProtocolDefinition definition) {
    final available = store.supports(selectedCore, definition.id);
    return div([
      button(
        [
          span([
            icon('connections'),
            txt(definition.name),
            icon('chevron'),
          ], classes: 'protocol-card-heading'),
          span([
            Component.text(t(definition.descriptionKey)),
          ], classes: 'protocol-description'),
          if (!available)
            txt(
              t(definition.unavailableKey ?? 'feature.unavailable'),
              classes: 'availability-chip',
            ),
        ],
        classes: 'protocol-select',
        type: ButtonType.button,
        disabled: dataBusy || !available,
        attributes: {'aria-label': definition.name},
        onClick: () => chooseProtocol(definition),
      ),
      FieldHelp(
        id: 'about-${definition.id}',
        label: definition.name,
        description: t(definition.detailsKey),
        buttonLabel: t('common.help', {'name': definition.name}),
        key: ValueKey('about:$selectedCore:${definition.id}'),
      ),
    ], classes: 'protocol-card ${available ? 'available' : 'unavailable'}');
  }

  Component productProtocolCard(ProductProtocol protocol) {
    final available = candidateEngines(protocol.id).isNotEmpty;
    return div([
      button(
        [
          span([
            icon('connections'),
            txt(protocol.name),
            icon('chevron'),
          ], classes: 'protocol-card-heading'),
          span([
            Component.text(t(protocol.descriptionKey)),
          ], classes: 'protocol-description'),
          if (!available)
            txt(
              t(protocol.tentative ? 'builder.planned' : 'feature.unavailable'),
              classes: 'availability-chip',
            ),
        ],
        type: ButtonType.button,
        classes: 'protocol-select',
        disabled: dataBusy || !available,
        onClick: () => chooseProtocol(
          ProtocolDefinition(protocol.id, protocol.name, const []),
        ),
      ),
      FieldHelp(
        id: 'about-${protocol.id}',
        label: protocol.name,
        description: t(protocol.detailsKey),
        buttonLabel: t('common.help', {'name': protocol.name}),
        key: ValueKey('product:${protocol.id}'),
      ),
    ], classes: 'protocol-card ${available ? 'available' : 'unavailable'}');
  }

  void changeField(ProtocolField f, String value) => setState(() {
    draft[f.id] = value;
    if (selectedCore != null && selectedProtocol != null)
      draft = store
          .definition(selectedCore!, selectedProtocol!)
          .defaults(draft);
    if (selectedCore != null && selectedProtocol != null) {
      final definition = store.definition(selectedCore!, selectedProtocol!);
      if (f.id == definition.clientFieldBindings['transport']) {
        final securityId = definition.clientFieldBindings['security'];
        final security = definition.fields
            .where((field) => field.id == securityId)
            .firstOrNull;
        if (security != null &&
            definition.exportRestrictions.any(
              (rule) => rule.matches(definition.clientValues(draft)),
            )) {
          for (final option in security.allowedOptions(draft)) {
            final candidate = definition.defaults({
              ...draft,
              security.id: option,
            });
            if (!definition.exportRestrictions.any(
              (rule) => rule.matches(definition.clientValues(candidate)),
            )) {
              draft = candidate;
              break;
            }
          }
        }
      }
    }
    connectionErrors.remove(f.id);
    error = null;
  });
  Map<String, String> blockedChoices(ProtocolField f) {
    if (selectedCore == null || selectedProtocol == null) return const {};
    final definition = store.definition(selectedCore!, selectedProtocol!);
    if (f.id != definition.clientFieldBindings['security']) return const {};
    return {
      for (final option in f.options)
        if (definition.exportRestrictions.any(
          (rule) => rule.matches(
            definition.clientValues(
              definition.defaults({...draft, f.id: option}),
            ),
          ),
        ))
          option: 'builder.profileUnavailable',
    };
  }

  Component field(ProtocolField f) {
    draft.putIfAbsent(f.id, () => f.initialValue(draft));
    final original = store.connections
        .where((c) => c.id == editingId)
        .firstOrNull;
    return ProtocolFieldView(
      field: f,
      values: draft,
      error: connectionErrors[f.id],
      busy: dataBusy,
      prefix: '$selectedCore-$selectedProtocol-',
      configured: original?.configuredSecrets.contains(f.id) == true,
      blockedOptions: blockedChoices(f),
      guideScope: selectedProtocol ?? '',
      onChanged: (value, rebuild) {
        if (rebuild) {
          changeField(f, value);
        } else {
          draft[f.id] = value;
          if (connectionErrors.containsKey(f.id))
            setState(() => connectionErrors.remove(f.id));
        }
      },
      key: ValueKey('field:$selectedCore:$selectedProtocol:${f.id}'),
    );
  }

  Component recipientForm() => div([
    label([
      Component.text(t('users.name')),
      input<String>(
        value: draft['name'],
        disabled: dataBusy || clearingLogs || ownerBusy,
        onInput: (v) => draft['name'] = v,
        attributes: {
          'autofocus': '',
          'maxlength': '80',
          'aria-required': 'true',
        },
      ),
    ]),
    h3([Component.text(t('users.access'))], classes: 'form-section-title'),
    div([
      for (final c in store.connections.where((c) => c.shareable))
        label([
          input<bool>(
            type: InputType.checkbox,
            checked: grants.contains(c.id),
            disabled: dataBusy || clearingLogs || ownerBusy,
            onChange: (v) => setState(() {
              if (v) {
                grants.add(c.id);
              } else {
                grants.remove(c.id);
              }
            }),
          ),
          div([
            txt(c.name),
            txt(
              c.port == null
                  ? store.protocol(c.protocolId).name
                  : '${store.protocol(c.protocolId).name} · :${c.port}',
              classes: 'muted small',
            ),
          ]),
          if (!c.enabled) txt(t('status.disabled'), classes: 'muted small'),
        ], classes: 'grant-option'),
    ], classes: 'grant-list'),
  ]);

  Component shareContent() {
    final user = sharing!;
    if (!user.enabled) return p([Component.text(t('share.disabled'))]);
    if (shareLoading) return p([Component.text(t('runtime.loading'))]);
    if (shareData == null) return div([]);
    final selected = int.tryParse(shareSelection) ?? -1;
    final artifact = selected >= 0 && selected < shareData!.links.length
        ? shareData!.links[selected]
        : null;
    final url = selected >= 0 && selected < shareData!.links.length
        ? shareData!.links[selected].payload
        : shareData!.subscriptionUrl;
    final qr = QrImage(
      QrCode.fromData(data: url, errorCorrectLevel: QrErrorCorrectLevel.M),
    );
    final size = qr.moduleCount + 8;
    return div([
      p([
        Component.text(t('share.description', {'name': user.name})),
      ]),
      select(
        [
          option(
            [Component.text(t('share.subscription'))],
            value: '-1',
            selected: shareSelection == '-1',
          ),
          for (var i = 0; i < shareData!.links.length; i++)
            option(
              [Component.text(shareData!.links[i].name)],
              value: '$i',
              selected: shareSelection == '$i',
            ),
        ],
        value: shareSelection,
        onChange: (v) => setState(() => shareSelection = v.first),
        attributes: {'aria-label': t('share.type')},
      ),
      div([
        el(
          'svg',
          [
            el(
              'rect',
              [],
              attributes: {'width': '$size', 'height': '$size', 'fill': '#fff'},
            ),
            for (var row = 0; row < qr.moduleCount; row++)
              for (var col = 0; col < qr.moduleCount; col++)
                if (qr.isDark(row, col))
                  el(
                    'rect',
                    [],
                    attributes: {
                      'x': '${col + 4}',
                      'y': '${row + 4}',
                      'width': '1',
                      'height': '1',
                      'fill': '#111',
                    },
                  ),
          ],
          attributes: {
            'viewBox': '0 0 $size $size',
            'shape-rendering': 'crispEdges',
            'role': 'img',
            'aria-label': url,
          },
        ),
      ], classes: 'qr-code'),
      txt(
        artifact?.content != null
            ? 'AmneziaWG 3.1 · .conf'
            : selected < 0
            ? t('share.format')
            : t('share.uriFormat', {
                'protocol': Uri.parse(url).scheme.toUpperCase(),
              }),
        classes: 'muted small',
      ),
      div([
        input<String>(
          value: url,
          attributes: {
            'readonly': '',
            'aria-label': t(
              selected < 0 ? 'share.subscriptionUrl' : 'share.uri',
            ),
          },
        ),
        iconButton('copy', t('common.copy'), () async {
          try {
            await web.window.navigator.clipboard.writeText(url).toDart;
            notify(t('common.copied'));
          } catch (_) {
            notify(t('common.copyFailed'));
          }
        }),
      ], classes: 'copy-field'),
      if (artifact?.content != null)
        action(t('maintenance.download'), () {
          final blob = web.Blob(
            [url.toJS].toJS,
            web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
          );
          final objectUrl = web.URL.createObjectURL(blob);
          final link = web.HTMLAnchorElement()
            ..href = objectUrl
            ..download = artifact!.filename ?? 'Sky-UI.conf';
          link.click();
          web.URL.revokeObjectURL(objectUrl);
        }, glyph: 'down'),
    ], classes: 'share-content');
  }
}
