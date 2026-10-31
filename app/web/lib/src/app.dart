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

class SkyApp extends StatefulComponent {
  const SkyApp({super.key});
  @override
  State<SkyApp> createState() => _SkyAppState();
}

class _SkyAppState extends State<SkyApp> {
  final store = PanelStore();
  PanelSnapshot? panelData;
  bool dataBusy = false;
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
      runtime?.platformSupported == true;
  final api = ApiClient();
  CoreSnapshot? runtime;
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
  CoreReleaseNotes? releaseNotes;
  bool releaseLoading = false;
  int releaseGeneration = 0;
  String? runtimeError;
  bool runtimeBusy = false;
  bool runtimeRefreshing = false;
  int runtimeGeneration = 0;
  Timer? runtimeTimer;

  bool get runtimeOnline => runtime != null && runtimeError == null;
  bool get runtimeRunning =>
      runtimeOnline && runtime!.processState == CoreProcessState.active;
  String get runtimeStatus => !runtimeOnline
      ? t(runtimeError == null ? 'runtime.loading' : 'runtime.offline')
      : t('runtime.state.${runtime!.processState.name}');

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
      final values = await Future.wait<Object>([api.core(), api.logs()]);
      if (!mounted || generation != runtimeGeneration) return;
      setState(() {
        runtime = values[0] as CoreSnapshot;
        if (!logsLive) runtimeLogs = values[1] as List<CoreLogEntry>;
        runtimeError = null;
        store.running = runtime!.processState == CoreProcessState.active;
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
    final source = web.EventSource('/api/v1/cores/primary/logs/events');
    logStream = source;
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
      await api.clearLogs();
      final entries = await api.logs();
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

  Future<void> openReleases(String core) async {
    final generation = ++releaseGeneration;
    releaseNotes = null;
    releaseLoading = true;
    openModal('releases');
    try {
      final notes = await api.releases(core);
      if (mounted && modal == 'releases' && generation == releaseGeneration)
        setState(() => releaseNotes = notes);
    } on ApiClientException catch (e) {
      if (mounted && modal == 'releases' && generation == releaseGeneration)
        setState(() => error = runtimeMessage(e.code));
    } finally {
      if (mounted && generation == releaseGeneration)
        setState(() => releaseLoading = false);
    }
  }

  Component releaseContent() {
    final notes = releaseNotes;
    if (releaseLoading) return p([Component.text(t('runtime.loading'))]);
    if (notes == null) return div([]);
    return div([
      txt(coreName(notes.coreId), classes: 'protocol-tag'),
      p([
        Component.text(
          t('core.releaseVersions', {
            'installed': notes.installed ?? t('core.notInstalled'),
            'latest': notes.latest,
          }),
        ),
      ], classes: 'muted'),
      if (notes.incomplete)
        p([Component.text(t('core.releaseIncomplete'))], classes: 'notice'),
      for (final release in notes.releases)
        div([
          h3([
            Component.text(release.name.isEmpty ? release.tag : release.name),
          ]),
          el(
            'a',
            [Component.text(release.tag)],
            attributes: {
              'href': release.url,
              'target': '_blank',
              'rel': 'noopener noreferrer',
            },
            classes: 'accent',
          ),
          el('pre', [
            Component.text(
              release.body.isEmpty ? t('core.releaseEmpty') : release.body,
            ),
          ], classes: 'release-text'),
        ], classes: 'release-entry'),
    ], classes: 'release-notes');
  }

  Future<void> runCoreAction(CoreOperation operation) async {
    if (dataBusy ||
        runtimeBusy ||
        !runtimeOnline ||
        !runtime!.operations.contains(operation))
      return;
    runtimeGeneration++;
    dataGeneration++;
    setState(() => runtimeBusy = true);
    try {
      final value = await api.execute(operation);
      if (mounted)
        setState(() {
          runtime = value;
          runtimeError = null;
          store.running = value.processState == CoreProcessState.active;
        });
    } on ApiClientException catch (e) {
      if (mounted) notify(runtimeMessage(e.code));
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
    store.running = false;
    unawaited(refreshRuntime());
    unawaited(refreshPanel());
    connectLogs();
    runtimeTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(refreshRuntime());
      unawaited(refreshPanel());
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
        setState(() => shareData = value);
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
    if (dataBusy || clearingLogs) return;
    releaseGeneration++;
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
    selectedProtocol = connection?.protocolId;
    selectedCore = connection?.coreId;
    draft = connection == null
        ? {'name': '', 'port': '8443'}
        : {
            'name': connection.name,
            'port': '${connection.port}',
            ...connection.settings,
          };
    if (connection != null) {
      for (final f in store.protocol(connection.protocolId).fields) {
        draft.putIfAbsent(f.id, () => f.defaultValue);
      }
    }
    openModal('connection');
  }

  void chooseCore(String coreId) {
    if (store.protocols[coreId]?.isNotEmpty != true) return;
    setState(() {
      selectedCore = coreId;
      selectedProtocol = null;
      draft = {'name': '', 'port': '8443'};
      error = null;
    });
  }

  void chooseProtocol(ProtocolDefinition protocol) {
    if (!store.supports(selectedCore, protocol.id)) return;
    protocol = store.definition(selectedCore!, protocol.id);
    setState(() {
      selectedProtocol = protocol.id;
      draft = {
        'name': draft['name'] ?? '',
        'port': draft['port'] ?? '8443',
        for (final f in protocol.fields) f.id: f.defaultValue,
      };
    });
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
    if (name.isEmpty || port == null || port < 1 || port > 65535) {
      setState(
        () => error = t(
          name.isEmpty ? 'common.invalidName' : 'common.invalidPort',
        ),
      );
      return;
    }
    if (definition.fields.any(
      (f) => f.required && (draft[f.id] ?? '').trim().isEmpty,
    )) {
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
      instanceId: old?.instanceId ?? 'primary',
      enabled: old?.enabled ?? true,
      settings: {
        for (final f in definition.fields) f.id: draft[f.id] ?? f.defaultValue,
      },
    );
    final id = editingId;
    await changePanel(
      () => api.saveConnection(draftRevision, value, id: id),
      dismiss: true,
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
            txt(
              '${t('app.name')} / ${const String.fromEnvironment('SKY_UI_VERSION', defaultValue: '0.2.0-dev')}',
            ),
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
        div([
          for (final core in coreCatalog)
            button(
              [
                div([
                  icon('core'),
                  txt(core.name),
                  span(
                    [],
                    classes:
                        'status-dot ${core.id == runtime?.coreId && runtimeRunning ? '' : 'off'}',
                  ),
                ], classes: 'sidebar-core-top'),
                div([
                  if (core.id == (runtime?.coreId ?? coreCatalog.first.id))
                    span(
                      [Component.text(runtime?.version ?? '—')],
                      classes: 'sidebar-core-version',
                      attributes: {'title': runtime?.version ?? '—'},
                    ),
                  txt(
                    core.id == (runtime?.coreId ?? coreCatalog.first.id)
                        ? runtimeStatus
                        : t('core.notInstalled'),
                    classes: 'muted',
                  ),
                ], classes: 'sidebar-core-detail'),
              ],
              classes: 'sidebar-core',
              type: ButtonType.button,
              onClick: () => navigate('core'),
            ),
        ], classes: 'sidebar-core-list'),
        div([
          txt('sky', classes: 'owner-name'),
          iconButton(
            'logout',
            t('admin.logoutUnavailable'),
            () {},
            disabled: true,
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
          Component.text(
            t(store.running ? 'status.running' : 'status.stopped'),
          ),
        ], classes: 'table-summary'),
        txt(
          '${runtime?.name ?? '—'} · ${store.serverName}',
          classes: 'mono muted',
        ),
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
          for (final width in [25, 15, 12, 11, 17, 10, 10])
            el('col', [], attributes: {'style': 'width: $width%'}),
        ]),
        el('thead', [
          el('tr', [
            for (final k in [
              'name',
              'protocol',
              'transport',
              'users',
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
                      c.port == null ? '—' : '${store.address}:${c.port}',
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
              el('td', [avatars(store.recipientsFor(c.id))]),
              el('td', [
                pill(
                  t(
                    dataBusy
                        ? 'data.applying'
                        : !c.enabled
                        ? 'status.disabled'
                        : store.recipientsFor(c.id).isEmpty
                        ? 'status.unassigned'
                        : !store.deliveryReady
                        ? 'status.stopped'
                        : 'status.active',
                  ),
                  positive:
                      !dataBusy &&
                      c.enabled &&
                      store.deliveryReady &&
                      store.recipientsFor(c.id).isNotEmpty,
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
                          attributes: {'title': c.name},
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
          runtime?.controllerReady == true
              ? 'system.coreHint'
              : 'system.coreNotReady',
          runtimeRunning && runtime?.controllerReady == true,
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

  Component corePage() {
    final value = runtime;
    final notice = runtimeBusy
        ? t('runtime.working')
        : runtimeError != null
        ? runtimeMessage(runtimeError!)
        : value?.error != null
        ? runtimeMessage(value!.error!.code)
        : '';
    final operation = runtimeRunning ? CoreOperation.stop : CoreOperation.start;
    bool can(CoreOperation op) =>
        runtimeOnline &&
        !runtimeBusy &&
        !dataBusy &&
        value!.operations.contains(op);
    return div([
      heading('core'),
      div([
        div([
          div([icon('core')], classes: 'core-large-icon'),
          div([
            txt(t('core.current'), classes: 'eyebrow'),
            h2([Component.text(value?.name ?? 'mihomo')]),
          ]),
          repositoryLink(value?.coreId ?? 'mihomo'),
          pill(runtimeStatus, positive: runtimeRunning),
        ], classes: 'core-header'),
        div([
          for (final fact in [
            (t('core.version'), value?.version ?? '—'),
            (t('core.service'), value?.service ?? 'sky-ui-mihomo.service'),
            (
              t('runtime.controller'),
              !runtimeOnline
                  ? '—'
                  : t(
                      value!.controllerReady
                          ? 'runtime.ready'
                          : 'runtime.notReady',
                    ),
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
          [Component.text(notice)],
          classes: 'runtime-notice ${notice.isEmpty ? 'empty' : ''}',
          attributes: {'role': 'status', 'aria-live': 'polite'},
        ),
        div([
          action(
            t(runtimeRunning ? 'core.stop' : 'core.start'),
            () => unawaited(runCoreAction(operation)),
            glyph: 'power',
            classes: 'button ${runtimeRunning ? '' : 'primary'}',
            disabled: !can(operation),
          ),
          action(
            t('core.restart'),
            () => unawaited(runCoreAction(CoreOperation.restart)),
            glyph: 'refresh',
            disabled: !can(CoreOperation.restart),
          ),
          action(
            t('runtime.validate'),
            () => unawaited(runCoreAction(CoreOperation.validate)),
            glyph: 'check',
            disabled: !can(CoreOperation.validate),
          ),
          action(
            t('core.refreshStatus'),
            () => unawaited(refreshRuntime()),
            glyph: 'refresh',
            disabled: runtimeBusy,
          ),
          action(t('core.update'), () {}, glyph: 'down', disabled: true),
          action(
            t('core.releases'),
            () => openReleases(value?.coreId ?? 'mihomo'),
            glyph: 'logs',
            disabled: !canInspect,
          ),
        ], classes: 'core-actions'),
      ], classes: 'panel core-panel live-core'),
      div([
        for (final core in const [
          CoreDescriptor('sing-box', 'sing-box'),
          CoreDescriptor('xray', 'Xray'),
        ])
          div([
            div([
              div([icon('core')], classes: 'core-large-icon'),
              h2([Component.text(core.name)]),
              repositoryLink(core.id),
              pill(t('core.notInstalled')),
            ], classes: 'core-header'),
            div([
              for (final key in [
                'core.version',
                'core.service',
                'runtime.controller',
                'core.memory',
              ])
                div([
                  txt(t(key), classes: 'muted small'),
                  txt('—', classes: 'mono'),
                ], classes: 'core-fact'),
            ], classes: 'core-facts'),
            div([], classes: 'runtime-notice empty'),
            div([
              action(t('core.install'), () {}, glyph: 'plus', disabled: true),
              action(
                t('core.releases'),
                () => openReleases(core.id),
                glyph: 'logs',
                disabled: !canInspect,
              ),
            ], classes: 'core-actions'),
          ], classes: 'panel core-panel'),
      ], classes: 'core-list'),
    ]);
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
      plannedSetting('admin.username', 'common.edit'),
      plannedSetting('admin.password', 'admin.changePassword'),
      plannedSetting('admin.sessions', 'admin.manageSessions'),
    ], classes: 'panel settings-panel'),
    div([
      h2([Component.text(t('settings.system'))]),
      plannedSetting('settings.domain', 'common.edit'),
      plannedSetting('settings.dns', 'settings.configure'),
      plannedSetting('settings.logging', 'settings.configure'),
    ], classes: 'panel settings-panel'),
  ]);
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
                  'releases' => 'core.releases',
                  _ => 'modal.deleteTitle',
                }),
              ),
            ], id: 'modal-title'),
            if (modal == 'connection')
              div([
                for (var step = 0; step < 3; step++) ...[
                  if (step > 0) icon('chevron'),
                  txt(
                    '${step + 1}  ${t(['modal.stepCore', 'modal.step1', 'modal.step2'][step])}',
                    classes:
                        step ==
                            (selectedCore == null
                                ? 0
                                : selectedProtocol == null
                                ? 1
                                : 2)
                        ? 'accent'
                        : 'muted',
                  ),
                ],
              ], classes: 'steps'),
          ]),
          iconButton(
            'close',
            t('common.close'),
            closeModal,
            classes: 'icon-button modal-close',
            disabled: dataBusy || clearingLogs,
          ),
        ], classes: 'modal-header'),
        div([
          if (modal == 'connection') connectionForm(),
          if (modal == 'recipient') recipientForm(),
          if (modal == 'share') shareContent(),
          if (modal == 'clearLogs') p([Component.text(t('logs.clearHint'))]),
          if (modal == 'releases') releaseContent(),
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
        if (modal != 'share' && modal != 'releases')
          div([
            if (modal == 'connection' &&
                selectedCore != null &&
                editingId == null)
              action(
                t('common.back'),
                () => setState(() {
                  if (selectedProtocol != null) {
                    selectedProtocol = null;
                  } else {
                    selectedCore = null;
                  }
                  error = null;
                }),
                classes: 'button ghost',
                disabled: dataBusy || clearingLogs,
              ),
            div([
              action(
                t('common.cancel'),
                closeModal,
                disabled: dataBusy || clearingLogs,
              ),
              if (modal == 'connection' && selectedProtocol != null)
                action(
                  t(editingId == null ? 'common.create' : 'common.save'),
                  saveConnection,
                  classes: 'button primary',
                  disabled:
                      !canEdit ||
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
      classes:
          'modal ${modal == 'connection' || modal == 'releases' ? 'wide' : ''}',
      attributes: {
        'role': 'dialog',
        'aria-modal': 'true',
        'aria-labelledby': 'modal-title',
      },
    ),
  ], classes: 'modal-overlay');

  Component connectionForm() {
    if (selectedCore == null)
      return div([
        div([
          for (final core in coreCatalog)
            button(
              [
                div([
                  icon('core'),
                  icon('chevron'),
                ], classes: 'protocol-option-top'),
                Component.text(core.name),
              ],
              classes: 'protocol-option core-option',
              type: ButtonType.button,
              disabled:
                  dataBusy || store.protocols[core.id]?.isNotEmpty != true,
              onClick: () => chooseCore(core.id),
            ),
        ], classes: 'protocol-grid core-grid'),
      ]);
    if (selectedProtocol == null)
      return div([
        txt(coreName(selectedCore!), classes: 'protocol-tag'),
        div([
          for (final protocol in protocolsForCore(selectedCore!))
            button(
              [
                icon('connections'),
                Component.text(protocol.name),
                icon('chevron'),
              ],
              classes: 'protocol-option protocol-choice',
              type: ButtonType.button,
              disabled: dataBusy || !store.supports(selectedCore, protocol.id),
              onClick: () => chooseProtocol(protocol),
            ),
        ], classes: 'protocol-grid'),
      ]);
    final definition = store.definition(selectedCore!, selectedProtocol!);
    if (!store.supports(selectedCore, selectedProtocol))
      return div([
        txt(definition.name, classes: 'protocol-tag'),
        p([Component.text(t('protocol.unavailable'))], classes: 'notice'),
      ]);
    return div([
      div([
        txt(coreName(selectedCore!), classes: 'protocol-tag'),
        txt(definition.name, classes: 'protocol-tag'),
      ], classes: 'selected-protocol'),
      if (runtime?.platformSupported == false)
        p([
          Component.text(runtimeMessage('platform_unsupported')),
        ], classes: 'notice'),
      h3([Component.text(t('modal.general'))], classes: 'form-section-title'),
      div([
        field(const ProtocolField('name', required: true)),
        if (definition.usesPort)
          field(const ProtocolField('port', required: true)),
      ], classes: 'form-grid'),
      h3([
        Component.text(t('modal.protocolSettings')),
      ], classes: 'form-section-title'),
      div([
        for (final f in definition.fields) field(f),
        if (draft['transport'] == 'WebSocket')
          field(const ProtocolField('path', defaultValue: '/connect')),
        if (draft['transport'] == 'gRPC')
          field(const ProtocolField('serviceName', defaultValue: 'tunnel')),
        if (draft['obfs'] == 'salamander')
          field(const ProtocolField('obfsPassword', secret: true)),
      ], classes: 'form-grid'),
    ]);
  }

  Component field(ProtocolField f) {
    draft.putIfAbsent(f.id, () => f.defaultValue);
    final controlId = 'field-${f.id}';
    return div([
      div([
        el(
          'label',
          [
            Component.text(t(f.labelKey)),
            if (f.required) txt(' *', classes: 'muted'),
          ],
          attributes: {'for': controlId},
        ),
        FieldHelp(
          id: 'help-${f.id}',
          label: t(f.labelKey),
          description: t(f.helpKey),
          buttonLabel: t('common.help', {'name': t(f.labelKey)}),
          key: ValueKey('help:$selectedCore:$selectedProtocol:${f.id}'),
        ),
      ], classes: 'field-label'),
      if (f.options.isNotEmpty)
        select(
          [
            for (final v in f.options) option([Component.text(v)], value: v),
          ],
          id: controlId,
          value: draft[f.id],
          onChange: (v) => setState(() => draft[f.id] = v.first),
          disabled: dataBusy || clearingLogs,
          key: ValueKey('$selectedProtocol-${f.id}'),
        )
      else
        input<String>(
          id: controlId,
          value: draft[f.id],
          disabled: dataBusy || clearingLogs,
          type: f.secret ? InputType.password : InputType.text,
          onInput: (v) => draft[f.id] = v,
          attributes: {
            'maxlength': f.id == 'name' ? '80' : '512',
            if (f.id == 'port') 'inputmode': 'numeric',
            if (f.required) 'aria-required': 'true',
          },
          key: ValueKey('$selectedProtocol-${f.id}'),
        ),
    ], classes: 'field');
  }

  Component recipientForm() => div([
    label([
      Component.text(t('users.name')),
      input<String>(
        value: draft['name'],
        disabled: dataBusy || clearingLogs,
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
      for (final c in store.connections)
        label([
          input<bool>(
            type: InputType.checkbox,
            checked: grants.contains(c.id),
            disabled: dataBusy || clearingLogs,
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
    final url = selected >= 0 && selected < shareData!.links.length
        ? shareData!.links[selected].uri
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
          option([Component.text(t('users.subscription'))], value: '-1'),
          for (var i = 0; i < shareData!.links.length; i++)
            option([Component.text(shareData!.links[i].name)], value: '$i'),
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
        selected < 0
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
            'aria-label': t(selected < 0 ? 'users.subscription' : 'share.uri'),
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
    ], classes: 'share-content');
  }
}
