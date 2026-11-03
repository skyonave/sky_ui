import 'dart:async';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/api_exception.dart';
import '../../engines/contracts.dart';
import '../access/records.dart';
import '../access/repository.dart';
import '../contracts/connection_diagnostics.dart';
import '../engines/core_manager.dart';
import '../engines/registry.dart';

/// Bounded, read-only diagnostics. Network work never holds configuration locks.
class ConnectionDiagnosticsService {
  ConnectionDiagnosticsService({
    required this.registry,
    required this.repository,
    required this.isSynchronized,
    required this.probe,
    this.cooldown = const Duration(seconds: 2),
    this.deadline = const Duration(seconds: 60),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final EngineRegistry registry;
  final AccessRepository repository;
  final Future<bool> Function() isSynchronized;
  final DiagnosticNetworkProbe probe;
  final Duration cooldown, deadline;
  final DateTime Function() now;
  final _runs = <String, _Run>{};
  _Run? _active;
  DateTime? _lastStart;
  bool _preparing = false, _disposed = false;

  void _prune() {
    final threshold = now().subtract(const Duration(minutes: 5));
    _runs.removeWhere(
      (_, run) => run != _active && run.started.isBefore(threshold),
    );
    while (_runs.length > 8) {
      final key = _runs.keys.firstWhere((key) => _runs[key] != _active);
      _runs.remove(key);
    }
  }

  Future<ConnectionDiagnostics> start(String connectionId, int revision) async {
    _prune();
    if (_disposed) throw const ApiException('diagnostics_unavailable');
    if (_active case final _Run run) {
      if (run.connection.id == connectionId &&
          run.revision == revision &&
          run.running)
        return run.snapshot();
      throw const ApiException('diagnostics_busy', status: 409);
    }
    if (_preparing) throw const ApiException('diagnostics_busy', status: 409);
    if (_lastStart != null && now().difference(_lastStart!) < cooldown)
      throw const ApiException('diagnostics_rate_limited', status: 429);
    _preparing = true;
    try {
      final context = await registry.exclusive((_) async {
        if (repository.revision != revision)
          throw const ApiException('state_changed', status: 409);
        if (repository.pending != null)
          throw const ApiException(
            'configuration_rollback_failed',
            status: 409,
          );
        final data = repository.read();
        final stored = data.connections
            .where((c) => c.value.id == connectionId)
            .firstOrNull;
        if (stored == null) throw const ApiException('not_found', status: 404);
        final owner = registry.owner(stored.value);
        final scoped = PanelData(
          serverName: data.serverName,
          address: data.address,
          connections: [stored],
          recipients: [...data.recipients],
          grants: data.grants
              .where((g) => g.connectionId == connectionId)
              .toList(),
        );
        final codec = registry.codec(stored.value.coreId);
        var plan = const ConnectionDiagnosticPlan(), planError = '';
        try {
          if (codec is ConnectionDiagnosticsCodec) {
            plan = (codec as ConnectionDiagnosticsCodec).diagnosticPlan(
              scoped,
              stored,
            );
          } else {
            planError = 'diagnostics_unsupported';
          }
        } on Object {
          // Invalid stored TLS fields/certificate selections must be visible in the report.
          planError = 'settings_invalid';
        }
        return _Context(
          owner,
          stored.value,
          scoped.activeGrants(connectionId).length,
          plan,
          planError,
        );
      });
      if (_disposed) throw const ApiException('diagnostics_unavailable');
      final run = _Run(newId('d'), context.connection, revision, now());
      for (final kind in ['configuration', 'access', 'engine', 'native']) {
        run.add(kind, kind);
      }
      for (var i = 0; i < context.plan.listeners.take(16).length; i++) {
        run.add('listener.$i', 'listener', context.plan.listeners[i].details);
      }
      if (context.plan.listeners.isEmpty || context.plan.listeners.length > 16)
        run.add('listeners', 'listeners');
      for (final kind in ['dns', 'tcp', 'tls', 'freshness']) {
        run.add(kind, kind, switch ((kind, context.plan.tls)) {
          ('dns', final DiagnosticTlsTarget target) => {'target': target.host},
          ('tcp', final DiagnosticTlsTarget target) => {
            'target': target.details['target']!,
          },
          ('tls', final DiagnosticTlsTarget target) => {
            'sni': target.serverName,
            'purpose': target.remote ? 'REALITY' : 'TLS',
          },
          _ => const {},
        });
      }
      _lastStart = now();
      _active = run;
      _runs[run.id] = run;
      _prune();
      unawaited(_execute(run, context));
      return run.snapshot();
    } finally {
      _preparing = false;
    }
  }

  ConnectionDiagnostics get(String connectionId, String id) {
    _prune();
    final run = _runs[id];
    if (run == null || run.connection.id != connectionId)
      throw const ApiException('not_found', status: 404);
    return run.snapshot();
  }

  ConnectionDiagnostics cancel(String connectionId, String id) {
    get(connectionId, id);
    final run = _runs[id]!;
    if (run.running) {
      run.cancellation.cancel();
      run.finish('cancelled', now(), 'cancelled');
    }
    return run.snapshot();
  }

  void dispose() {
    _disposed = true;
    _active?.cancellation.cancel();
  }

  Future<void> _execute(_Run run, _Context context) async {
    final timer = Timer(deadline, () {
      if (!run.running) return;
      var current = run.checks.indexWhere(
        (check) => check.state == DiagnosticState.running,
      );
      if (current < 0)
        current = run.checks.indexWhere((check) => !check.finished);
      if (current >= 0)
        run.checks[current] = run.checks[current].copyWith(
          state: DiagnosticState.failed,
          code: 'diagnostic_timeout',
        );
      run.cancellation.cancel();
      run.finish('completed', now(), 'blocked');
    });
    Future<DiagnosticProbeResult> check(
      String id,
      Future<DiagnosticProbeResult> Function() action,
    ) async {
      run.cancellation.check();
      final index = run.checks.indexWhere((c) => c.id == id);
      run.checks[index] = run.checks[index].copyWith(
        state: DiagnosticState.running,
        code: 'running',
      );
      final watch = Stopwatch()..start();
      DiagnosticProbeResult result;
      try {
        result = await action();
      } on DiagnosticCancelled {
        rethrow;
      } on Object {
        result = const DiagnosticProbeResult(
          DiagnosticState.warning,
          'check_failed',
        );
      }
      run.cancellation.check();
      run.checks[index] = run.checks[index].copyWith(
        state: result.state,
        code: result.code,
        details: {...run.checks[index].details, ...result.details},
        durationMs: watch.elapsedMilliseconds,
      );
      return result;
    }

    Future<void> skip(String id, String code) => check(
      id,
      () async => DiagnosticProbeResult(DiagnosticState.skipped, code),
    );
    ServiceObservation? observation;
    try {
      final config = await check('configuration', () async {
        if (!await isSynchronized())
          return const DiagnosticProbeResult(
            DiagnosticState.failed,
            'configuration_out_of_sync',
          );
        if (context.planError.isNotEmpty)
          return DiagnosticProbeResult(
            context.planError == 'diagnostics_unsupported'
                ? DiagnosticState.warning
                : DiagnosticState.failed,
            context.planError,
          );
        return const DiagnosticProbeResult(
          DiagnosticState.passed,
          'configuration_ready',
        );
      });
      await check(
        'access',
        () async => !context.connection.enabled
            ? const DiagnosticProbeResult(
                DiagnosticState.warning,
                'connection_disabled',
              )
            : context.grants == 0 && context.connection.shareable
            ? const DiagnosticProbeResult(
                DiagnosticState.warning,
                'no_recipients',
              )
            : DiagnosticProbeResult(DiagnosticState.passed, 'access_ready', {
                'recipients': '${context.grants}',
              }),
      );
      CoreSnapshot? core;
      await context.owner.exclusive((_) async {
        await check('engine', () async {
          core = await context.owner.snapshot();
          observation = await context.owner.supervisor.inspect(
            context.owner.core,
          );
          final details = {
            'service': context.owner.core.service,
            'version': core!.version ?? '—',
            'state': core!.processState.name,
            if (observation!.processId != null)
              'pid': '${observation!.processId}',
          };
          if (!core!.binaryAvailable)
            return DiagnosticProbeResult(
              DiagnosticState.failed,
              'binary_missing',
              details,
            );
          if (!core!.platformSupported)
            return DiagnosticProbeResult(
              DiagnosticState.warning,
              'platform_unsupported',
              details,
            );
          if (!observation!.loaded)
            return DiagnosticProbeResult(
              DiagnosticState.failed,
              'service_missing',
              details,
            );
          if (core!.processState != CoreProcessState.active)
            return DiagnosticProbeResult(
              DiagnosticState.failed,
              core!.processState == CoreProcessState.failed
                  ? 'core_failed'
                  : 'core_stopped',
              details,
            );
          if (!core!.controllerReady)
            return DiagnosticProbeResult(
              DiagnosticState.failed,
              'controller_not_ready',
              details,
            );
          return DiagnosticProbeResult(
            DiagnosticState.passed,
            'engine_ready',
            details,
          );
        });
        if (core?.binaryAvailable != true) {
          await skip('native', 'binary_missing');
          return;
        }
        await check('native', () async {
          try {
            await context.owner.adapter.validate(context.owner.core);
            return const DiagnosticProbeResult(
              DiagnosticState.passed,
              'native_ready',
            );
          } on ApiException catch (e) {
            return DiagnosticProbeResult(
              e.code == 'command_unavailable' || e.code == 'command_timeout'
                  ? DiagnosticState.warning
                  : DiagnosticState.failed,
              switch (e.code) {
                'command_unavailable' => 'validator_missing',
                'command_timeout' => 'validator_timeout',
                _ => 'native_invalid',
              },
            );
          }
        });
      });
      var listenersReady = context.plan.listeners.isNotEmpty;
      for (var i = 0; i < context.plan.listeners.take(16).length; i++) {
        final listener = context.plan.listeners[i];
        final result = await check('listener.$i', () async {
          if (!config.passed || observation?.state != CoreProcessState.active)
            return const DiagnosticProbeResult(
              DiagnosticState.skipped,
              'blocked',
            );
          return probe.listener(
            listener,
            observation?.processId,
            run.cancellation,
          );
        });
        listenersReady &= result.passed;
      }
      if (context.plan.listeners.isEmpty ||
          context.plan.listeners.length > 16) {
        await check(
          'listeners',
          () async => context.plan.listeners.isEmpty
              ? DiagnosticProbeResult(
                  DiagnosticState.skipped,
                  context.connection.enabled
                      ? 'no_active_listeners'
                      : 'connection_disabled',
                )
              : DiagnosticProbeResult(
                  DiagnosticState.warning,
                  'listeners_sampled',
                  {
                    'checked': '16',
                    'total': '${context.plan.listeners.length}',
                  },
                ),
        );
      }
      final target = context.plan.tls;
      if (target == null ||
          !config.passed ||
          !context.connection.enabled ||
          !target.remote && !listenersReady) {
        final code = !config.passed || target != null
            ? 'blocked'
            : context.plan.tlsSkipCode;
        await skip('dns', code);
        await skip('tcp', code);
        await check(
          'tls',
          () async => DiagnosticProbeResult(
            code == 'target_invalid'
                ? DiagnosticState.failed
                : DiagnosticState.skipped,
            code,
          ),
        );
      } else {
        DiagnosticResolution? resolution;
        await check('dns', () async {
          resolution = await probe.resolve(target, run.cancellation);
          return resolution!.result;
        });
        if (resolution?.result.passed == true) {
          final tcp = await check(
            'tcp',
            () => probe.tcp(target, resolution!.addresses, run.cancellation),
          );
          final address = tcp.details['address'];
          if (tcp.passed &&
              address != null &&
              resolution!.addresses.contains(address)) {
            await check(
              'tls',
              () => probe.tls(target, address, run.cancellation),
            );
          } else {
            await skip('tls', 'blocked');
          }
        } else {
          await skip('tcp', 'blocked');
          await skip('tls', 'blocked');
        }
      }
      await check('freshness', () async {
        if (repository.revision != run.revision ||
            repository.pending != null ||
            !await isSynchronized())
          return const DiagnosticProbeResult(
            DiagnosticState.warning,
            'state_changed',
          );
        final latest = await context.owner.supervisor.inspect(
          context.owner.core,
        );
        if (observation != null &&
            (observation!.state != latest.state ||
                observation!.processId != latest.processId))
          return const DiagnosticProbeResult(
            DiagnosticState.warning,
            'state_changed',
          );
        return const DiagnosticProbeResult(
          DiagnosticState.passed,
          'snapshot_current',
        );
      });
      run.finish('completed', now(), 'blocked');
    } on DiagnosticCancelled {
      if (run.running) run.finish('cancelled', now(), 'cancelled');
    } on Object {
      if (run.running) {
        final index = run.checks.indexWhere((c) => !c.finished);
        if (index >= 0)
          run.checks[index] = run.checks[index].copyWith(
            state: DiagnosticState.failed,
            code: 'check_failed',
          );
        run.finish('completed', now(), 'blocked');
      }
    } finally {
      timer.cancel();
      if (_active == run) _active = null;
    }
  }
}

class _Context {
  const _Context(
    this.owner,
    this.connection,
    this.grants,
    this.plan,
    this.planError,
  );
  final CoreManager owner;
  final Connection connection;
  final int grants;
  final ConnectionDiagnosticPlan plan;
  final String planError;
}

class _Run {
  _Run(this.id, this.connection, this.revision, this.started);
  final String id;
  final Connection connection;
  final int revision;
  final DateTime started;
  final cancellation = DiagnosticCancellation();
  final checks = <DiagnosticCheck>[];
  String status = 'running';
  DateTime? finished;
  bool get running => status == 'running';
  void add(String id, String kind, [Map<String, String> details = const {}]) =>
      checks.add(DiagnosticCheck(id: id, kind: kind, details: details));
  void finish(String value, DateTime time, String skipped) {
    if (!running) return;
    status = value;
    finished = time;
    for (var i = 0; i < checks.length; i++) {
      if (!checks[i].finished)
        checks[i] = checks[i].copyWith(
          state: DiagnosticState.skipped,
          code: skipped,
        );
    }
  }

  ConnectionDiagnostics snapshot() => ConnectionDiagnostics(
    id: id,
    connectionId: connection.id,
    connectionName: connection.name,
    coreId: connection.coreId,
    instanceId: connection.instanceId,
    revision: revision,
    startedAt: started.toUtc().toIso8601String(),
    status: status,
    finishedAt: finished?.toUtc().toIso8601String(),
    checks: List.unmodifiable(checks),
  );
}
