import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:web/web.dart' as web;

import '../../shared/api/api_client.dart';
import '../../shared/localization/strings.dart';
import '../../shared/state/panel_store.dart';

/// Owns live engine observations, telemetry and the log stream lifecycle.
class RuntimeController {
  RuntimeController({
    required this.api,
    required this.store,
    required this.readPanel,
    required this.isDataBusy,
    required this.isAlive,
    required this.isLogsPage,
    required this.onSignedOut,
    required this.onChanged,
  });
  final ApiClient api;
  final PanelStore store;
  final PanelSnapshot? Function() readPanel;
  final bool Function() isDataBusy, isAlive, isLogsPage;
  final void Function() onSignedOut, onChanged;
  final t = const AppStrings();
  Map<String, RecipientPresence> _presence = const {};
  int? _presenceRevision;
  DateTime? _presenceExpires;
  bool _presenceRefreshing = false;
  Map<String, RecipientPresence> get presence =>
      !dataBusy &&
          _presenceRevision == panelData?.revision &&
          (_presenceExpires?.isAfter(DateTime.now()) ?? false)
      ? _presence
      : const {};

  Future<void> refreshPresence() async {
    if (_presenceRefreshing || dataBusy || panelData == null) return;
    _presenceRefreshing = true;
    final revision = panelData!.revision;
    final generation = runtimeGeneration;
    try {
      final value = await api.recipientPresence();
      if (!mounted ||
          generation != runtimeGeneration ||
          value.revision != revision ||
          panelData?.revision != revision)
        return;
      final current = presence;
      final changed =
          value.recipients.length != current.length ||
          value.recipients.entries.any((e) => current[e.key] != e.value);
      _presence = value.recipients;
      _presenceRevision = revision;
      _presenceExpires = DateTime.now().add(const Duration(seconds: 6));
      if (changed) onChanged();
    } on ApiClientException {
      if (generation == runtimeGeneration && _presence.isNotEmpty)
        _change(() => _presence = const {});
    } finally {
      _presenceRefreshing = false;
    }
  }

  bool get mounted => isAlive();
  bool get dataBusy => isDataBusy();
  PanelSnapshot? get panelData => readPanel();
  void _change(void Function() update) {
    if (!mounted) return;
    update();
    onChanged();
  }

  void dispose() {
    logStream?.close();
    logStream = null;
    runtimeGeneration++;
  }

  String selectedLogInstance = 'sky-ui';
  CoreSnapshot? runtime;
  List<CoreSnapshot> runtimes = [];
  List<CoreLogEntry> runtimeLogs = [];
  SystemSnapshot? system;
  bool systemRefreshing = false, followingLogs = true, logsLive = false;
  final selectedLogLevels = <String>{
    'trace',
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
      _change(() {
        runtimes = values[0] as List<CoreSnapshot>;
        runtime = runtimes.where((v) => v.instanceId == 'primary').firstOrNull;
        if (!logsLive) runtimeLogs = values[1] as List<CoreLogEntry>;
        runtimeError = null;
        store.running = runtimeRunning;
      });
    } on ApiClientException catch (e) {
      if (mounted && generation == runtimeGeneration)
        _change(() {
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
        _change(() {
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
          onSignedOut();
        }
      }).toJS,
    );
    source.addEventListener(
      'open',
      ((web.Event _) {
        if (mounted && logStream == source) _change(() => logsLive = true);
      }).toJS,
    );
    source.addEventListener(
      'error',
      ((web.Event _) {
        if (mounted && logStream == source) _change(() => logsLive = false);
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
            _change(() => runtimeLogs = entries);
        } on Object {}
      }).toJS,
    );
  }

  void scheduleLogTail() {
    if (!followingLogs || !isLogsPage()) return;
    Timer(const Duration(milliseconds: 20), () {
      if (!mounted || !followingLogs || !isLogsPage()) return;
      final view =
          web.document.querySelector('.runtime-log') as web.HTMLElement?;
      if (view != null) view.scrollTop = view.scrollHeight.toDouble();
    });
  }
}
