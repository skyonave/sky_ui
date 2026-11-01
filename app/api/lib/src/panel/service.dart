import 'dart:io';
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

class PanelService {
  PanelService({
    required this.config,
    required this.manager,
    required this.repository,
    required Map<String, ConfigurationCodec> codecs,
    required this.exporter,
    List<ClientExporter> additionalExporters = const [],
  }) : exporters = {
         exporter.format: exporter,
         for (final item in additionalExporters) item.format: item,
       },
       codec =
           codecs[manager.core.coreId] ??
           (throw const ApiException('core_unsupported', status: 422));
  final ServerConfig config;
  final CoreManager manager;
  final PanelRepository repository;
  final ConfigurationCodec codec;
  final ClientExporter exporter;
  final Map<String, ClientExporter> exporters;
  bool busy = false;
  final _portRandom = Random.secure();

  Future<void> initialize() => manager.exclusive((control) async {
    final pending = repository.pending;
    if (pending == null) return;
    busy = true;
    try {
      await _publish(pending.previous);
      final observation = await manager.supervisor.inspect(manager.core);
      if (observation.state == CoreProcessState.active ||
          (pending.wasRunning && manager.desired != CoreDesiredState.stopped)) {
        await control.execute(
          observation.state == CoreProcessState.active
              ? CoreOperation.restart
              : CoreOperation.start,
          remember: false,
        );
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
    final expected = repository.configurationHash;
    if (expected == null) return true;
    try {
      return digest(await File(manager.core.configuration).readAsString()) ==
          expected;
    } on FileSystemException {
      return false;
    }
  }

  Future<PanelSnapshot> snapshot() => manager.exclusive((_) => _snapshot());
  Future<PanelSnapshot> _snapshot() async {
    final data = repository.read();
    final synchronized = await isSynchronized();
    final core = await manager.snapshot();
    var ready =
        !busy &&
        synchronized &&
        core.controllerReady &&
        core.processState == CoreProcessState.active;
    String? readinessError;
    if (ready) {
      try {
        await codec.verifyRunning(data, manager.core);
      } on ApiException catch (e) {
        ready = false;
        readinessError = e.code;
      }
    }
    return PanelSnapshot(
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
      deliveryReady: ready && core.binaryAvailable,
      coreAvailability: {core.coreId: core.binaryAvailable},
      protocols: {
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
    if (!(await manager.snapshot()).binaryAvailable)
      throw const ApiException('binary_missing', status: 409);
    if (!manager.supervisor.supported)
      throw const ApiException('platform_unsupported', status: 501);
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

  Future<void> _publish(String text) =>
      _staged(text, 'published.yaml', (file) async {
        await file.rename(manager.core.configuration);
      });

  Future<PanelSnapshot> _change(
    int revision,
    Future<void> Function(PanelData) update,
  ) => manager.exclusive((control) async {
    await _check(revision);
    busy = true;
    var prepared = false;
    String? previous;
    var wasRunning = false;
    try {
      final before = repository.read();
      final after = before.copy();
      await update(after);
      final observation = await manager.supervisor.inspect(manager.core);
      if (!observation.loaded)
        throw const ApiException('service_missing', status: 409);
      if (![
        CoreProcessState.active,
        CoreProcessState.inactive,
        CoreProcessState.failed,
      ].contains(observation.state)) {
        throw const ApiException('service_busy', status: 409);
      }
      wasRunning = observation.state == CoreProcessState.active;
      previous = await File(manager.core.configuration).readAsString();
      final candidate = codec.compile(after, manager.core, previous);
      final validation = codec.compile(
        after,
        manager.core,
        previous,
        validationOnly: true,
      );
      if (validation != candidate || candidate != previous)
        await _staged(
          validation,
          'draft.validate',
          (file) => control.validateCandidate(file.path),
        );
      if (candidate != previous) {
        if (validation != candidate)
          await _staged(
            candidate,
            'candidate.validate',
            (file) => control.validateCandidate(file.path),
          );
        await codec.preflight(before, after, wasRunning);
        repository.prepare(DeploymentIntent(previous, candidate, wasRunning));
        prepared = true;
        await _publish(candidate);
        if (wasRunning) {
          // Restart closes existing sessions, making revocation effective immediately.
          await control.execute(CoreOperation.restart, remember: false);
          await codec.verifyRunning(after, manager.core);
        }
      }
      repository.commit(after, candidate);
      prepared = false;
      manager.event('configuration_applied');
    } on Object catch (e) {
      if (prepared && previous != null) {
        try {
          await _publish(previous);
          if (wasRunning)
            await control.execute(CoreOperation.restart, remember: false);
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
    if (id != null && old == null)
      throw const ApiException('not_found', status: 404);
    if (input.coreId != manager.core.coreId ||
        input.instanceId != manager.core.id)
      throw const ApiException('core_unavailable', status: 422);
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
        {22, 80, 443, config.port, manager.core.controller.port}.contains(port))
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
      final definition = codec.protocols.firstWhere(
        (p) => p.id == c.value.protocolId,
      );
      final credentials = await codec.grantCredentials(c);
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
      manager.core.controller.port,
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
          codec.clientEndpoint(c, grant, data.address),
    ];
  }

  Future<void> _canExport() async {
    if (busy) throw const ApiException('configuration_busy', status: 503);
    if (!await isSynchronized())
      throw const ApiException('configuration_out_of_sync', status: 503);
    final core = await manager.snapshot();
    if (!core.binaryAvailable)
      throw const ApiException('binary_missing', status: 503);
    if (core.processState != CoreProcessState.active || !core.controllerReady)
      throw const ApiException('core_not_ready', status: 503);
    await codec.verifyRunning(repository.read(), manager.core);
  }

  Future<RecipientShare> share(String id) => manager.exclusive((_) async {
    await _canExport();
    final data = repository.read();
    final user = data.recipients.where((u) => u.id == id).firstOrNull;
    if (user == null || !user.enabled)
      throw const ApiException('not_found', status: 404);
    final endpoints = _clientEndpoints(data, id);
    final links = exporter.links(endpoints);
    return RecipientShare(
      subscriptionUrl: config.webOrigin
          .resolve('/s/${user.token}.yaml')
          .toString(),
      links: links,
      subscriptionUrls: {
        'clash': config.webOrigin.resolve('/s/${user.token}.yaml').toString(),
        if (V2RayExporter().canExport(endpoints))
          'v2ray': config.webOrigin.resolve('/s/${user.token}.txt').toString(),
      },
    );
  });
  Future<String> subscription(String token, {String format = 'clash'}) =>
      manager.exclusive((_) async {
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
        await _canExport();
        final endpoints = _clientEndpoints(data, id);
        return switch (format) {
          'clash' => exporter.profile(endpoints),
          'v2ray' => V2RayExporter().profile(endpoints),
          _ => throw const ApiException('export_unavailable', status: 422),
        };
      });
  Future<CoreSnapshot> executeCore(CoreOperation operation) =>
      manager.exclusive((control) async {
        if ([CoreOperation.start, CoreOperation.restart].contains(operation) &&
            !await isSynchronized()) {
          throw const ApiException('configuration_out_of_sync', status: 409);
        }
        final result = await control.execute(operation);
        if ([CoreOperation.start, CoreOperation.restart].contains(operation))
          await codec.verifyRunning(repository.read(), manager.core);
        return result;
      });
  Future<void> restoreCore() async {
    if (manager.desired == CoreDesiredState.unknown) return;
    await executeCore(
      manager.desired == CoreDesiredState.running
          ? CoreOperation.start
          : CoreOperation.stop,
    );
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
