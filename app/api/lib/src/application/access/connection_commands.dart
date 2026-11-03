import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/api_exception.dart';
import '../contracts/access_environment.dart';
import '../engines/core_manager.dart';
import '../engines/registry.dart';
import 'records.dart';
import 'validation.dart';

/// Mutates a draft only; ConfigurationTransaction owns all persistence/activation.
class ConnectionCommands {
  ConnectionCommands({
    required this.config,
    required this.registry,
    required this.portProbe,
  });
  final AccessEnvironment config;
  final EngineRegistry registry;
  final Future<bool> Function(int) portProbe;
  Map<String, CoreManager> get managers => registry.managers;
  Future<void> save(PanelData data, Connection input, {String? id}) async {
    final old = data.connections.where((c) => c.value.id == id).firstOrNull;
    registry.owner(input);
    final codec = registry.codec(input.coreId);
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
    final name = validatedName(input.name);
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
  }
}
