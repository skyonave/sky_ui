import 'dart:io';
import 'dart:math';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/api_exception.dart';
import '../contracts/access_environment.dart';
import '../contracts/configuration_codec.dart';
import '../engines/core_manager.dart';
import '../engines/registry.dart';
import 'records.dart';
import 'validation.dart';

/// Recipient identity, grants and isolated ports change in one application draft.
class RecipientCommands {
  RecipientCommands({required this.config, required this.registry});
  final AccessEnvironment config;
  final EngineRegistry registry;
  final _portRandom = Random.secure();
  Map<String, CoreManager> get managers => registry.managers;
  Future<void> save(PanelData data, Recipient input, {String? id}) async {
    final old = data.recipients
        .where((u) => u.id == id && u.parentId == null)
        .firstOrNull;
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
      name: validatedName(input.name),
      enabled: input.enabled,
      token: old?.token ?? secureToken(),
    );
    if (old == null) {
      data.recipients.add(user);
    } else {
      data.recipients[data.recipients.indexOf(old)] = user;
    }
    await _syncGrants(data, user, selected);
    final deviceConnections = selected
        .where((id) => _requiresDeviceGrant(data, id))
        .toSet();
    for (final device in data.recipients.where((u) => u.parentId == user.id)) {
      await _syncGrants(data, device, deviceConnections);
    }
  }

  bool _requiresDeviceGrant(PanelData data, String connectionId) {
    final connection = data.connections.firstWhere(
      (c) => c.value.id == connectionId,
    );
    final codec = registry.codec(connection.value.coreId);
    return codec is DeviceGrantPolicy &&
        (codec as DeviceGrantPolicy).requiresDeviceGrant(connection);
  }

  Future<void> enroll(
    PanelData data,
    StoredRecipient parent,
    StoredRecipient device,
  ) async {
    data.recipients.add(device);
    await _syncGrants(data, device, {
      for (final grant in data.grants)
        if (grant.recipientId == parent.id &&
            _requiresDeviceGrant(data, grant.connectionId))
          grant.connectionId,
    });
  }

  Future<void> _syncGrants(
    PanelData data,
    StoredRecipient user,
    Set<String> selected,
  ) async {
    data.grants.removeWhere(
      (g) => g.recipientId == user.id && !selected.contains(g.connectionId),
    );
    for (final connectionId in selected) {
      if (data.grants.any(
        (g) => g.recipientId == user.id && g.connectionId == connectionId,
      ))
        continue;
      final c = data.connections.firstWhere((c) => c.value.id == connectionId);
      final codec = registry.codec(c.value.coreId);
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
  }

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
}
