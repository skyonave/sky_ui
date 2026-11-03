import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import '../config.dart';
import '../core_manager.dart';
import '../errors.dart';
import 'client_exporter.dart';
import 'configuration_codec.dart';
import 'domain.dart';
import 'repository.dart';
import 'validation.dart';
import 'connection_tools.dart';

class PanelService {
  PanelService({
    required this.config,
    required this.manager,
    required this.repository,
    required Map<String, ConfigurationCodec> codecs,
    required this.exporter,
    this.portProbe = connectionPortAvailable,
    List<CoreManager> additionalManagers = const [],
    List<ClientExporter> additionalExporters = const [],
  }) : exporters = {
         exporter.format: exporter,
         for (final item in additionalExporters) item.format: item,
       },
       codecs = codecs,
       managers = {
         manager.core.id: manager,
         for (final item in additionalManagers) item.core.id: item,
       };
  final ServerConfig config;
  final Future<bool> Function(int) portProbe;
  final CoreManager manager;
  final PanelRepository repository;
  final Map<String, ConfigurationCodec> codecs;
  final Map<String, CoreManager> managers;
  ConfigurationCodec get codec => codecs[manager.core.coreId]!;
  ConfigurationCodec _codec(String id) =>
      codecs[id] ?? (throw const ApiException('core_unsupported', status: 422));
  CoreManager _owner(Connection connection) {
    final owner = managers[connection.instanceId];
    if (owner == null || owner.core.coreId != connection.coreId)
      throw const ApiException('core_unavailable', status: 422);
    return owner;
  }

  Future<T> _exclusive<T>(Future<T> Function(Map<String, CoreControl>) action) {
    final ordered = managers.keys.toList()..sort();
    final controls = <String, CoreControl>{};
    Future<T> lock(int index) => index == ordered.length
        ? action(controls)
        : managers[ordered[index]]!.exclusive((control) {
            controls[ordered[index]] = control;
            return lock(index + 1);
          });
    return lock(0);
  }

  final ClientExporter exporter;
  final Map<String, ClientExporter> exporters;
  bool busy = false;
  final _portRandom = Random.secure();

  Future<CoreSettings> coreSettings(String id) => _exclusive((_) async {
    final owner = managers[id];
    if (owner == null)
      throw const ApiException('core_unavailable', status: 404);
    final native = _codec(owner.core.coreId);
    if (native is! CoreSettingsCodec)
      throw const ApiException('core_settings_unavailable', status: 501);
    await _check(repository.revision);
    if (!(await owner.snapshot()).binaryAvailable)
      throw const ApiException('binary_missing', status: 409);
    return CoreSettings(
      instanceId: id,
      coreId: owner.core.coreId,
      revision: repository.revision,
      fields: (native as CoreSettingsCodec).coreSettingsFields,
      values: (native as CoreSettingsCodec).readCoreSettings(
        await File(owner.core.configuration).readAsString(),
        repository.read().coreSettings[id],
      ),
    );
  });

  Future<PanelSnapshot> saveCoreSettings(
    int revision,
    String id,
    Map<String, String> values,
  ) => _change(revision, (data) async {
    final owner = managers[id];
    if (owner == null)
      throw const ApiException('core_unavailable', status: 404);
    final native = _codec(owner.core.coreId);
    if (native is! CoreSettingsCodec)
      throw const ApiException('core_settings_unavailable', status: 501);
    if (!(await owner.snapshot()).binaryAvailable)
      throw const ApiException('binary_missing', status: 409);
    data.coreSettings[id] = (native as CoreSettingsCodec).prepareCoreSettings(
      await File(owner.core.configuration).readAsString(),
      data.coreSettings[id],
      values,
    );
  });

  Future<Map<String, String>> generateConnectionFields(
    int revision,
    String coreId,
    String protocolId,
    String fieldId,
    Map<String, String> values,
  ) => _exclusive((_) async {
    final data = repository.read();
    await _check(revision);
    final definition = _codec(
      coreId,
    ).protocols.where((p) => p.id == protocolId && p.available).firstOrNull;
    if (definition == null)
      throw const ApiException('protocol_unavailable', status: 422);
    final current = definition.defaults(values), result = <String, String>{};
    if (fieldId == 'port' ||
        fieldId == 'defaults' && (values['port'] ?? '').isEmpty) {
      final reserved = <int>{
        22,
        80,
        443,
        config.port,
        for (final owner in managers.values) owner.core.controller.port,
        for (final c in data.connections)
          if (c.value.port != null) c.value.port!,
        for (final g in data.grants)
          if (int.tryParse(g.credentials['port'] ?? '') != null)
            int.parse(g.credentials['port']!),
        if (int.tryParse(values['port'] ?? '') != null)
          int.parse(values['port']!),
      };
      result['port'] =
          '${await randomConnectionPort(reserved, probe: portProbe)}';
      if (fieldId == 'port') return result;
    }
    for (final field in definition.activeFields(current)) {
      if (field.generator == null ||
          fieldId != 'defaults' && field.id != fieldId ||
          result.containsKey(field.id))
        continue;
      result.addAll(
        generateConnectionValue(field.id, field.generator!, {
          ...current,
          ...result,
        }),
      );
    }
    if (result.isEmpty && fieldId != 'defaults')
      throw const ApiException('generation_unsupported', status: 422);
    return result;
  });

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

  Future<void> initialize() => _exclusive((controls) async {
    final pending = repository.pending;
    if (pending == null) return;
    busy = true;
    try {
      for (final entry in _recovery(pending).entries) {
        final owner = managers[entry.key];
        if (owner == null) throw const ApiException('core_unavailable');
        await _publish(entry.value['previous'] as String, owner);
        final observation = await owner.supervisor.inspect(owner.core);
        if (observation.state == CoreProcessState.active ||
            (entry.value['wasRunning'] == true &&
                owner.desired != CoreDesiredState.stopped)) {
          await controls[entry.key]!.execute(
            observation.state == CoreProcessState.active
                ? CoreOperation.restart
                : CoreOperation.start,
            remember: false,
          );
        }
      }
      repository.clearPending();
      manager.event('configuration_recovered');
    } on Object {
      manager.event('configuration_rollback_failed', level: 'error');
      // Keep the durable intent: exports and changes remain blocked until recovery.
    } finally {
      busy = false;
    }
  });

  Future<bool> isSynchronized() async {
    if (repository.pending != null) return false;
    for (final owner in managers.values) {
      final expected = repository.instanceHash(owner.core.id);
      if (expected == null) continue;
      try {
        if (digest(await File(owner.core.configuration).readAsString()) !=
            expected)
          return false;
      } on FileSystemException {
        return false;
      }
    }
    return true;
  }

  Future<PanelSnapshot> snapshot() => _exclusive((_) => _snapshot());
  Future<PanelSnapshot> _snapshot() async {
    final data = repository.read();
    final synchronized = await isSynchronized();
    final snapshots = {
      for (final owner in managers.values)
        owner.core.id: await owner.snapshot(),
    };
    final core = snapshots[manager.core.id]!;
    final readiness = <String, bool>{};
    String? readinessError;
    for (final owner in managers.values) {
      final observed = snapshots[owner.core.id]!;
      var ready =
          !busy &&
          synchronized &&
          observed.binaryAvailable &&
          observed.controllerReady &&
          observed.processState == CoreProcessState.active;
      if (ready) {
        try {
          await _codec(
            owner.core.coreId,
          ).verifyRunning(data.forInstance(owner.core.id), owner.core);
        } on ApiException catch (e) {
          ready = false;
          readinessError = e.code;
        }
      }
      readiness[owner.core.id] = ready;
    }
    return PanelSnapshot(
      settingsInstances: [
        for (final owner in managers.values)
          if (_codec(owner.core.coreId) is CoreSettingsCodec) owner.core.id,
      ],
      revision: repository.revision,
      connections: data.connections
          .map(
            (c) => c.value.copyWith(
              assignedPorts: data
                  .activeGrants(c.value.id)
                  .where(
                    (g) =>
                        g.connectionId == c.value.id &&
                        g.credentials.containsKey('port'),
                  )
                  .map((g) => int.parse(g.credentials['port']!))
                  .toList(),
            ),
          )
          .toList(),
      recipients: data.recipients.map(data.publicRecipient).toList(),
      serverName: data.serverName,
      address: data.address,
      synchronized: synchronized,
      deliveryReady: readiness.values.any((v) => v),
      coreAvailability: {
        for (final value in snapshots.values)
          value.coreId: value.binaryAvailable,
      },
      instanceIds: {
        for (final owner in managers.values) owner.core.coreId: owner.core.id,
      },
      instanceReadiness: readiness,
      protocols: {
        for (final codec in codecs.values)
          codec.coreId: codec.protocols
              .map((p) => p.withExportRestrictions(exporter.restrictions))
              .toList(),
      },
      errorCode: !core.binaryAvailable
          ? 'binary_missing'
          : repository.pending != null
          ? 'configuration_rollback_failed'
          : synchronized
          ? readinessError
          : 'configuration_out_of_sync',
    );
  }

  Future<void> _check(int revision) async {
    if (revision != repository.revision)
      throw const ApiException('state_changed', status: 409);
    if (repository.pending != null)
      throw const ApiException('configuration_rollback_failed', status: 503);
    if (!await isSynchronized())
      throw const ApiException('configuration_out_of_sync', status: 409);
  }

  // Stage outside the core-owned directory so it cannot replace a candidate
  // path with a link to private API data.
  Future<T> _staged<T>(
    String text,
    String name,
    Future<T> Function(File) action,
  ) async {
    final root = await Directory(
      '${config.dataDirectory}/staging',
    ).create(recursive: true);
    final parent = await root.resolveSymbolicLinks();
    final temporary = await Directory(parent).createTemp('deployment-');
    final resolved = await temporary.resolveSymbolicLinks();
    if (!resolved.startsWith('$parent${Platform.pathSeparator}'))
      throw StateError('Invalid staging directory.');
    try {
      final file = File('$resolved/$name');
      await file.writeAsString(text, flush: true);
      if (Platform.isLinux) {
        final result = await Process.run('/usr/bin/chmod', ['0640', file.path]);
        if (result.exitCode != 0)
          throw const ApiException('configuration_write_failed', status: 500);
      }
      return await action(file);
    } finally {
      final target = await temporary.resolveSymbolicLinks();
      if (target != resolved ||
          !target.startsWith('$parent${Platform.pathSeparator}'))
        throw StateError('Unsafe staging cleanup.');
      await temporary.delete(recursive: true);
    }
  }

  Future<void> _publish(String text, [CoreManager? owner]) =>
      _staged(text, 'published.yaml', (file) async {
        await file.rename((owner ?? manager).core.configuration);
      });

  Future<PanelSnapshot> _change(
    int revision,
    Future<void> Function(PanelData) update,
  ) => _exclusive((controls) async {
    await _check(revision);
    busy = true;
    var prepared = false;
    final changes = <String, Map<String, dynamic>>{};
    final configurations = <String, String>{};
    try {
      final before = repository.read();
      final after = before.copy();
      await update(after);
      for (final owner in managers.values) {
        final native = _codec(owner.core.coreId);
        final oldData = before.forInstance(owner.core.id);
        final newData = after.forInstance(owner.core.id);
        final file = File(owner.core.configuration);
        if (!await file.exists()) {
          if (newData.connections.isNotEmpty)
            throw const ApiException('binary_missing', status: 409);
          continue;
        }
        final previous = await file.readAsString();
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
              .map((u) => [u.id, u.enabled])
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
          await _staged(
            validation,
            'draft.${owner.core.coreId == 'mihomo' ? 'yaml' : 'json'}',
            (file) => controls[owner.core.id]!.validateCandidate(file.path),
          );
        if (candidate != previous) {
          if (validation != candidate)
            await _staged(
              candidate,
              'candidate.${owner.core.coreId == 'mihomo' ? 'yaml' : 'json'}',
              (file) => controls[owner.core.id]!.validateCandidate(file.path),
            );
          await native.preflight(oldData, newData, wasRunning);
          changes[owner.core.id] = {
            'previous': previous,
            'candidate': candidate,
            'wasRunning': wasRunning,
          };
        }
      }
      if (changes.isNotEmpty) {
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
          await _publish(entry.value['candidate'] as String, owner);
          if (entry.value['wasRunning'] == true) {
            await controls[entry.key]!.execute(
              CoreOperation.restart,
              remember: false,
            );
            await _codec(
              owner.core.coreId,
            ).verifyRunning(after.forInstance(entry.key), owner.core);
          }
        }
      }
      repository.commit(
        after,
        configurations[manager.core.id] ??
            repository.metadata('configuration') ??
            '',
        configurations: configurations,
      );
      prepared = false;
      manager.event('configuration_applied');
    } on Object catch (e) {
      if (prepared) {
        try {
          for (final entry in changes.entries.toList().reversed) {
            final owner = managers[entry.key]!;
            await _publish(entry.value['previous'] as String, owner);
            if (entry.value['wasRunning'] == true)
              await controls[entry.key]!.execute(
                CoreOperation.restart,
                remember: false,
              );
          }
          repository.clearPending();
          manager.event('configuration_rolled_back', level: 'error');
        } on Object {
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
    return _snapshot();
  });

  Future<PanelSnapshot> saveConnection(
    int revision,
    Connection input, {
    String? id,
  }) => _change(revision, (data) async {
    final old = data.connections.where((c) => c.value.id == id).firstOrNull;
    _owner(input);
    final codec = _codec(input.coreId);
    if (id != null && old == null)
      throw const ApiException('not_found', status: 404);
    if (old == null && productProtocol(input.protocolId) == null)
      throw const ApiException('protocol_unavailable', status: 422);
    if (old != null &&
        (old.value.coreId != input.coreId ||
            old.value.protocolId != input.protocolId ||
            old.value.instanceId != input.instanceId)) {
      throw const ApiException('connection_identity_immutable', status: 422);
    }
    final name = _name(input.name);
    final definition = codec.protocols
        .where((p) => p.id == input.protocolId && p.available)
        .firstOrNull;
    if (definition == null)
      throw const ApiException('protocol_unavailable', status: 422);
    final port = definition.usesPort ? input.port : null;
    if (definition.usesPort && (port == null || port < 1 || port > 65535))
      throw const ApiException('port_invalid', status: 422);
    if (port != null &&
        {
          22,
          80,
          443,
          config.port,
          for (final m in managers.values) m.core.controller.port,
        }.contains(port))
      throw const ApiException('port_reserved', status: 422);
    if (port != null &&
        (data.connections.any(
              (c) => c.value.id != id && c.value.port == port,
            ) ||
            data.grants.any(
              (g) => g.connectionId != id && g.credentials['port'] == '$port',
            )))
      throw const ApiException('port_in_use', status: 422);
    if (definition.isolatedBindings &&
        old != null &&
        old.value.port != port &&
        data.grants.any((g) => g.credentials['port'] == '$port'))
      throw const ApiException('port_in_use', status: 422);
    if (port != null &&
        (old == null || old.value.port != port) &&
        !await portProbe(port)) {
      throw const ApiException('port_in_use', status: 422);
    }
    final secretInput = {...input.settings};
    for (final f
        in definition
            .activeFields(definition.defaults(input.settings))
            .where((f) => f.secret)) {
      if ((secretInput[f.id] ?? '').isEmpty &&
          old?.secrets['field:${f.id}'] != null)
        secretInput[f.id] = old!.secrets['field:${f.id}']!;
    }
    final settings = codec.validateSettings(
      Connection(
        id: input.id,
        name: input.name,
        coreId: input.coreId,
        protocolId: input.protocolId,
        instanceId: input.instanceId,
        port: input.port,
        enabled: input.enabled,
        settings: secretInput,
      ),
    );
    final secretIds = definition.fields
        .where((f) => f.secret)
        .map((f) => f.id)
        .toSet();
    final value = Connection(
      id: id ?? newId('c'),
      name: name,
      coreId: input.coreId,
      instanceId: input.instanceId,
      protocolId: input.protocolId,
      port: port,
      enabled: input.enabled,
      settings: settings,
      shareable: definition.shareable,
    );
    final secrets = await codec.connectionSecrets(
      value,
      previous: old?.secrets ?? const {},
    );
    for (final key in secretIds) {
      if ((settings[key] ?? '').isNotEmpty)
        secrets['field:$key'] = settings[key]!;
    }
    final safeValue = Connection(
      id: value.id,
      name: value.name,
      coreId: value.coreId,
      instanceId: value.instanceId,
      protocolId: value.protocolId,
      port: value.port,
      enabled: value.enabled,
      shareable: value.shareable,
      settings: Map.from(settings)
        ..removeWhere((key, _) => secretIds.contains(key)),
      configuredSecrets: secretIds
          .where((key) => secrets.containsKey('field:$key'))
          .toList(),
    );
    final record = StoredConnection(safeValue, secrets);
    for (var i = 0; i < data.grants.length; i++) {
      final grant = data.grants[i];
      if (grant.connectionId != value.id) continue;
      data.grants[i] = AccessGrant(
        id: grant.id,
        recipientId: grant.recipientId,
        connectionId: grant.connectionId,
        credentials: await codec.grantCredentials(
          record,
          previous: grant.credentials,
        ),
      );
    }
    if (definition.isolatedBindings &&
        old != null &&
        old.value.port != value.port) {
      for (var i = 0; i < data.grants.length; i++) {
        final grant = data.grants[i];
        if (grant.connectionId == value.id &&
            grant.credentials['port'] == '${old.value.port}')
          data.grants[i] = AccessGrant(
            id: grant.id,
            recipientId: grant.recipientId,
            connectionId: grant.connectionId,
            credentials: {...grant.credentials, 'port': '${value.port}'},
          );
      }
    }
    if (old == null) {
      data.connections.add(record);
    } else {
      data.connections[data.connections.indexOf(old)] = record;
    }
  });
  Future<PanelSnapshot> deleteConnection(int revision, String id) =>
      _change(revision, (data) async {
        if (!data.connections.any((c) => c.value.id == id))
          throw const ApiException('not_found', status: 404);
        data.grants.removeWhere((g) => g.connectionId == id);
        data.connections.removeWhere((c) => c.value.id == id);
      });
  Future<PanelSnapshot> saveRecipient(
    int revision,
    Recipient input, {
    String? id,
  }) => _change(revision, (data) async {
    final old = data.recipients.where((u) => u.id == id).firstOrNull;
    if (id != null && old == null)
      throw const ApiException('not_found', status: 404);
    final selected = input.connectionIds.toSet();
    if (selected.length != input.connectionIds.length ||
        selected.any(
          (c) => !data.connections.any(
            (v) => v.value.id == c && v.value.shareable,
          ),
        )) {
      throw const ApiException('grant_invalid', status: 422);
    }
    final user = StoredRecipient(
      id: id ?? newId('u'),
      name: _name(input.name),
      enabled: input.enabled,
      token: old?.token ?? secureToken(),
    );
    if (old == null) {
      data.recipients.add(user);
    } else {
      data.recipients[data.recipients.indexOf(old)] = user;
    }
    data.grants.removeWhere(
      (g) => g.recipientId == user.id && !selected.contains(g.connectionId),
    );
    for (final connectionId in selected) {
      if (data.grants.any(
        (g) => g.recipientId == user.id && g.connectionId == connectionId,
      ))
        continue;
      final c = data.connections.firstWhere((c) => c.value.id == connectionId);
      final codec = _codec(c.value.coreId);
      final definition = codec.protocols.firstWhere(
        (p) => p.id == c.value.protocolId,
      );
      var credentials = await codec.grantCredentials(c);
      if (codec is GrantAllocator)
        credentials = (codec as GrantAllocator).allocateGrant(
          data,
          c,
          credentials,
        );
      if (definition.isolatedBindings)
        credentials['port'] = '${await _allocateGrantPort(data, c)}';
      data.grants.add(
        AccessGrant(
          id: newId('g'),
          recipientId: user.id,
          connectionId: connectionId,
          credentials: credentials,
        ),
      );
    }
  });

  Future<int> _allocateGrantPort(
    PanelData data,
    StoredConnection connection,
  ) async {
    final reserved = {
      22,
      80,
      443,
      config.port,
      for (final owner in managers.values) owner.core.controller.port,
      for (final c in data.connections)
        if (c.value.id != connection.value.id && c.value.port != null)
          c.value.port!,
      for (final g in data.grants)
        if (g.credentials['port'] != null) int.parse(g.credentials['port']!),
    };
    for (var attempt = 0; attempt < 200; attempt++) {
      final candidate = attempt == 0
          ? connection.value.port!
          : 20000 + _portRandom.nextInt(40000);
      if (reserved.contains(candidate)) continue;
      ServerSocket? tcp;
      RawDatagramSocket? udp;
      try {
        if (candidate >= 1024) {
          tcp = await ServerSocket.bind(
            connection.value.settings['listen'] ?? '::',
            candidate,
            shared: false,
          );
          udp = await RawDatagramSocket.bind(
            connection.value.settings['listen'] ?? '::',
            candidate,
            reuseAddress: false,
            reusePort: false,
          );
        }
        return candidate;
      } on SocketException {
        reserved.add(candidate);
      } finally {
        await tcp?.close();
        udp?.close();
      }
    }
    throw const ApiException('port_unavailable', status: 422);
  }

  Future<PanelSnapshot> deleteRecipient(int revision, String id) =>
      _change(revision, (data) async {
        if (!data.recipients.any((u) => u.id == id))
          throw const ApiException('not_found', status: 404);
        data.grants.removeWhere((g) => g.recipientId == id);
        data.recipients.removeWhere((u) => u.id == id);
      });
  Future<PanelSnapshot> saveSettings(
    int revision,
    String name,
    String address,
  ) => _change(revision, (data) async {
    if (!validAddress(address.trim()))
      throw const ApiException('address_invalid', status: 422);
    data.serverName = _name(name);
    data.address = address.trim();
  });
  List<ClientEndpoint> _clientEndpoints(PanelData data, String recipientId) {
    if (!data.recipients.any((u) => u.id == recipientId && u.enabled))
      throw const ApiException('not_found', status: 404);
    return [
      for (final c in data.connections.where((c) => c.value.enabled))
        for (final grant in data.grants.where(
          (g) => g.recipientId == recipientId && g.connectionId == c.value.id,
        ))
          _codec(c.value.coreId).clientEndpoint(c, grant, data.address),
    ];
  }

  Future<void> _canExport(
    String recipientId, {
    Set<String>? connectionIds,
  }) async {
    if (busy) throw const ApiException('configuration_busy', status: 503);
    if (!await isSynchronized())
      throw const ApiException('configuration_out_of_sync', status: 503);
    final data = repository.read();
    final owned = data.connections
        .where(
          (c) =>
              c.value.enabled &&
              (connectionIds == null || connectionIds.contains(c.value.id)) &&
              data.grants.any(
                (g) =>
                    g.connectionId == c.value.id &&
                    g.recipientId == recipientId,
              ),
        )
        .map((c) => c.value.instanceId)
        .toSet();
    for (final id in owned) {
      final owner = managers[id];
      if (owner == null)
        throw const ApiException('core_unavailable', status: 503);
      final core = await owner.snapshot();
      if (!core.binaryAvailable)
        throw const ApiException('binary_missing', status: 503);
      if (core.processState != CoreProcessState.active || !core.controllerReady)
        throw const ApiException('core_not_ready', status: 503);
      await _codec(
        owner.core.coreId,
      ).verifyRunning(data.forInstance(id), owner.core);
    }
  }

  Future<RecipientShare> share(String id) => _exclusive((_) async {
    await _canExport(id);
    final data = repository.read();
    final user = data.recipients.where((u) => u.id == id).firstOrNull;
    if (user == null || !user.enabled)
      throw const ApiException('not_found', status: 404);
    final endpoints = _clientEndpoints(data, id);
    final links = ShareUriCodec().links(endpoints);
    return RecipientShare(
      subscriptionUrl: config.webOrigin.resolve('/s/${user.token}').toString(),
      links: links,
      subscriptionUrls: {
        if (exportableEndpoints(exporter, endpoints).isNotEmpty)
          'clash': config.webOrigin.resolve('/s/${user.token}.yaml').toString(),
        if (exportableEndpoints(V2RayExporter(), endpoints).isNotEmpty)
          'v2ray': config.webOrigin.resolve('/s/${user.token}.txt').toString(),
      },
    );
  });
  Future<String> subscription(
    String token, {
    String format = 'clash',
    String? clientId,
  }) => _exclusive((_) async {
    final id = repository.recipientForToken(token);
    if (id == null) throw const ApiException('not_found', status: 404);
    final data = repository.read();
    if (!data.recipients.any((u) => u.id == id && u.enabled))
      throw const ApiException('not_found', status: 404);
    if (!data.grants.any(
      (g) =>
          g.recipientId == id &&
          data.connections.any(
            (c) => c.value.id == g.connectionId && c.value.enabled,
          ),
    )) {
      throw const ApiException('not_found', status: 404);
    }
    final endpoints = _clientEndpoints(data, id);
    final client = format == 'clash'
        ? exporter
        : format == 'v2ray'
        ? V2RayExporter()
        : null;
    if (client == null)
      throw const ApiException('export_unavailable', status: 422);
    final selected = exportableEndpoints(client, endpoints, client: clientId);
    if (selected.isEmpty)
      throw const ApiException('export_unavailable', status: 422);
    final selectedIds = {
      for (final grant in data.grants)
        if (selected.any((endpoint) => endpoint.id == grant.id))
          grant.connectionId,
    };
    await _canExport(id, connectionIds: selectedIds);
    return switch (format) {
      'clash' => exporter.profile(selected),
      'v2ray' => V2RayExporter().profile(selected),
      _ => throw const ApiException('export_unavailable', status: 422),
    };
  });
  Future<CoreSnapshot> executeCore(
    CoreOperation operation, {
    String? instanceId,
  }) {
    final owner = managers[instanceId ?? manager.core.id];
    if (owner == null)
      throw const ApiException('instance_not_found', status: 404);
    return owner.exclusive((control) async {
      if ([CoreOperation.start, CoreOperation.restart].contains(operation) &&
          !await isSynchronized()) {
        throw const ApiException('configuration_out_of_sync', status: 409);
      }
      final result = await control.execute(operation);
      if ([CoreOperation.start, CoreOperation.restart].contains(operation)) {
        try {
          await _codec(owner.core.coreId).verifyRunning(
            repository.read().forInstance(owner.core.id),
            owner.core,
          );
        } on Object {
          await control.execute(CoreOperation.stop);
          rethrow;
        }
      }
      return result;
    });
  }

  Future<void> restoreCore() async {
    for (final owner in managers.values) {
      if (owner.desired == CoreDesiredState.unknown) continue;
      try {
        await executeCore(
          owner.desired == CoreDesiredState.running
              ? CoreOperation.start
              : CoreOperation.stop,
          instanceId: owner.core.id,
        );
      } on Object {
        owner.event('core_state_restore_failed', level: 'error');
      }
    }
  }
}

String _name(String value) {
  final name = value.trim();
  if (name.isEmpty ||
      name.length > 80 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(name))
    throw const ApiException('name_invalid', status: 422);
  return name;
}
