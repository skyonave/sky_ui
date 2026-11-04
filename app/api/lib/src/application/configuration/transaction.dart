import 'dart:convert';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/api_exception.dart';
import '../access/records.dart';
import '../access/repository.dart';
import '../contracts/configuration_store.dart';
import '../engines/core_manager.dart';
import '../engines/registry.dart';
import '../logs/panel_log.dart';

/// Owns the durable validate/publish/activate/commit/rollback boundary.
class ConfigurationTransaction {
  ConfigurationTransaction({
    required this.registry,
    required this.repository,
    required this.files,
    required this.log,
  });
  final EngineRegistry registry;
  final AccessRepository repository;
  final ConfigurationStore files;
  final PanelLog log;
  CoreManager get manager => registry.primary;
  Map<String, CoreManager> get managers => registry.managers;
  bool busy = false;
  Map<String, dynamic> _recovery(DeploymentIntent intent) {
    try {
      final value = jsonDecode(intent.previous);
      if (value is Map && value['skyUiDeployment'] == 2)
        return Map<String, dynamic>.from(value['instances'] as Map);
    } on FormatException {}
    return {
      manager.core.id: {
        'previous': intent.previous,
        'wasRunning': intent.wasRunning,
      },
    };
  }

  Future<void> initialize() => registry.exclusive((controls) async {
    final pending = repository.pending;
    if (pending == null) return;
    busy = true;
    try {
      for (final entry in _recovery(pending).entries) {
        final owner = managers[entry.key];
        if (owner == null) throw const ApiException('core_unavailable');
        await _restore(owner, controls[entry.key]!, entry.value as Map);
      }
      repository.clearPending();
      log.event('Configuration recovery completed');
      manager.event('configuration_recovered');
    } on Object {
      log.event('Configuration recovery failed', level: 'error');
      manager.event('configuration_rollback_failed', level: 'error');
      // Keep the durable intent: exports and changes remain blocked until recovery.
    } finally {
      busy = false;
    }
  });

  Future<void> _restore(
    CoreManager owner,
    CoreControl control,
    Map change,
  ) async {
    if (change['autoStart'] == true) {
      // Stop an engine that could have started with an uncommitted grant.
      await control.execute(CoreOperation.stop, remember: false);
    }
    await files.publish(change['previous'] as String, owner.core);
    if (change['autoStart'] == true) return;
    final observed = await owner.supervisor.inspect(owner.core);
    if (observed.state == CoreProcessState.active ||
        change['wasRunning'] == true &&
            owner.desired != CoreDesiredState.stopped) {
      await control.execute(
        observed.state == CoreProcessState.active
            ? CoreOperation.restart
            : CoreOperation.start,
        remember: false,
      );
    }
  }

  Future<bool> isSynchronized() async {
    if (repository.pending != null) return false;
    for (final owner in managers.values) {
      final expected = repository.instanceHash(owner.core.id);
      if (expected == null) continue;
      if (!await files.matches(owner.core, expected)) return false;
    }
    return true;
  }

  Future<void> checkRevision(int revision) async {
    if (revision != repository.revision)
      throw const ApiException('state_changed', status: 409);
    if (repository.pending != null)
      throw const ApiException('configuration_rollback_failed', status: 503);
    if (!await isSynchronized())
      throw const ApiException('configuration_out_of_sync', status: 409);
  }

  Future<T> apply<T>(
    int revision,
    Future<void> Function(PanelData) update,
    Future<T> Function() complete,
  ) => registry.exclusive((controls) async {
    await checkRevision(revision);
    busy = true;
    var prepared = false;
    var stage = 'update access records';
    final changes = <String, Map<String, dynamic>>{};
    final configurations = <String, String>{};
    try {
      final before = repository.read();
      final after = before.copy();
      await update(after);
      for (final owner in managers.values) {
        stage = 'validate ${owner.core.coreId} configuration';
        final native = registry.codec(owner.core.coreId);
        final oldData = before.forInstance(owner.core.id);
        final newData = after.forInstance(owner.core.id);
        final previous = await files.read(owner.core);
        if (previous == null) {
          if (newData.connections.isNotEmpty)
            throw const ApiException('binary_missing', status: 409);
          continue;
        }
        String signature(PanelData data) => jsonEncode({
          'coreSettings': data.coreSettings,
          'connections': data.connections
              .map((c) => {'value': c.value.toJson(), 'secrets': c.secrets})
              .toList(),
          'grants': data.grants
              .map((g) => [g.id, g.recipientId, g.connectionId, g.credentials])
              .toList(),
          'recipients': data.recipients
              .where((u) => data.grants.any((g) => g.recipientId == u.id))
              .map((u) => [u.id, data.recipientEnabled(u)])
              .toList(),
        });
        if (signature(oldData) == signature(newData)) {
          configurations[owner.core.id] = previous;
          continue;
        }
        final candidate = native.compile(newData, owner.core, previous);
        configurations[owner.core.id] = candidate;
        if (!(await owner.snapshot()).binaryAvailable) {
          final unchangedConnections = newData.connections.every((c) {
            final old = oldData.connections
                .where((o) => o.value.id == c.value.id)
                .firstOrNull;
            if (old == null || !old.value.enabled && c.value.enabled)
              return false;
            final value = old.value.toJson()..['enabled'] = c.value.enabled;
            return jsonEncode(value) == jsonEncode(c.value.toJson()) &&
                jsonEncode(old.secrets) == jsonEncode(c.secrets);
          });
          final previousGrants = oldData.grants
              .map(
                (g) => jsonEncode([
                  g.id,
                  g.connectionId,
                  g.recipientId,
                  g.credentials,
                ]),
              )
              .toSet();
          final previousActive = {
            for (final c in oldData.connections)
              ...oldData.activeGrants(c.value.id).map((g) => g.id),
          };
          final reductionsOnly =
              unchangedConnections &&
              newData.grants.every(
                (g) => previousGrants.contains(
                  jsonEncode([
                    g.id,
                    g.connectionId,
                    g.recipientId,
                    g.credentials,
                  ]),
                ),
              ) &&
              newData.connections.every(
                (c) => newData
                    .activeGrants(c.value.id)
                    .every((g) => previousActive.contains(g.id)),
              );
          if (!reductionsOnly ||
              (await owner.supervisor.inspect(owner.core)).state ==
                  CoreProcessState.active)
            throw const ApiException('binary_missing', status: 409);
          // Revocation remains possible after removal. Reinstallation validates
          // the stored native document before the engine can serve it again.
          if (candidate != previous)
            changes[owner.core.id] = {
              'previous': previous,
              'candidate': candidate,
              'wasRunning': false,
            };
          continue;
        }
        if (!owner.supervisor.supported)
          throw const ApiException('platform_unsupported', status: 501);
        final observation = await owner.supervisor.inspect(owner.core);
        if (!observation.loaded)
          throw const ApiException('service_missing', status: 409);
        if (![
          CoreProcessState.active,
          CoreProcessState.inactive,
          CoreProcessState.failed,
        ].contains(observation.state)) {
          throw const ApiException('service_busy', status: 409);
        }
        final wasRunning = observation.state == CoreProcessState.active;
        final validation = native.compile(
          newData,
          owner.core,
          previous,
          validationOnly: true,
        );
        if (validation != candidate || candidate != previous)
          await files.stage(
            validation,
            'draft.${owner.core.coreId == 'mihomo' ? 'yaml' : 'json'}',
            (path) => controls[owner.core.id]!.validateCandidate(path),
          );
        final autoStart =
            !wasRunning &&
            owner.desired != CoreDesiredState.stopped &&
            newData.listeningConnections.isNotEmpty;
        if (candidate != previous || autoStart) {
          if (validation != candidate)
            await files.stage(
              candidate,
              'candidate.${owner.core.coreId == 'mihomo' ? 'yaml' : 'json'}',
              (path) => controls[owner.core.id]!.validateCandidate(path),
            );
          await native.preflight(oldData, newData, wasRunning);
          changes[owner.core.id] = {
            'previous': previous,
            'candidate': candidate,
            'wasRunning': wasRunning,
            if (autoStart) 'autoStart': true,
          };
        }
      }
      if (changes.isNotEmpty) {
        stage = 'prepare configuration deployment';
        final intent = jsonEncode({'skyUiDeployment': 2, 'instances': changes});
        // The existing durable row remains the single recovery/maintenance barrier.
        repository.prepare(
          DeploymentIntent(
            intent,
            intent,
            changes.values.any((c) => c['wasRunning'] == true),
          ),
        );
        prepared = true;
        for (final entry in changes.entries) {
          final owner = managers[entry.key]!;
          stage = 'publish ${owner.core.coreId} configuration';
          await files.publish(entry.value['candidate'] as String, owner.core);
          if (entry.value['wasRunning'] == true ||
              entry.value['autoStart'] == true) {
            stage = 'activate ${owner.core.coreId} configuration';
            log.event(stage);
            await controls[entry.key]!.execute(
              entry.value['autoStart'] == true
                  ? CoreOperation.start
                  : CoreOperation.restart,
              remember: false,
            );
            stage = 'verify ${owner.core.coreId} listeners';
            await registry
                .codec(owner.core.coreId)
                .verifyRunning(after.forInstance(entry.key), owner.core);
          }
        }
      }
      stage = 'commit configuration';
      repository.commit(
        after,
        configurations[manager.core.id] ??
            repository.metadata('configuration') ??
            '',
        configurations: configurations,
      );
      prepared = false;
      log.event('Configuration applied');
      manager.event('configuration_applied');
    } on Object catch (e) {
      log.event(
        'Failed to $stage',
        level: e is ApiException && e.status < 500 ? 'warning' : 'error',
      );
      if (prepared) {
        try {
          for (final entry in changes.entries.toList().reversed) {
            final owner = managers[entry.key]!;
            await _restore(owner, controls[entry.key]!, entry.value);
          }
          repository.clearPending();
          log.event('Configuration rolled back', level: 'warning');
          manager.event('configuration_rolled_back', level: 'error');
        } on Object {
          log.event('Configuration rollback failed', level: 'error');
          throw const ApiException(
            'configuration_rollback_failed',
            status: 503,
          );
        }
      }
      if (e is ApiException) rethrow;
      throw const ApiException('configuration_write_failed', status: 500);
    } finally {
      busy = false;
    }
    return complete();
  });
}
