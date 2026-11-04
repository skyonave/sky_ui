import 'dart:convert';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/api_exception.dart';
import '../access/records.dart';
import '../access/repository.dart';
import '../contracts/access_environment.dart';
import '../contracts/configuration_codec.dart';
import '../engines/core_manager.dart';
import '../engines/registry.dart';
import 'client_exporter.dart';

class SubscriptionService {
  SubscriptionService({
    required this.config,
    required this.registry,
    required this.repository,
    required this.exporter,
    required this.isBusy,
    required this.isSynchronized,
  });
  final AccessEnvironment config;
  final EngineRegistry registry;
  final AccessRepository repository;
  final ClientExporter exporter;
  final bool Function() isBusy;
  final Future<bool> Function() isSynchronized;
  bool get busy => isBusy();
  Map<String, CoreManager> get managers => registry.managers;
  ConfigurationCodec _codec(String id) => registry.codec(id);
  Future<T> _exclusive<T>(
    Future<T> Function(Map<String, CoreControl>) action,
  ) => registry.exclusive(action);
  Iterable<AccessGrant> _grants(PanelData data, String recipientId) sync* {
    final recipient = data.recipients
        .where((u) => u.id == recipientId)
        .firstOrNull;
    if (recipient == null || !data.recipientEnabled(recipient))
      throw const ApiException('not_found', status: 404);
    for (final connection in data.connections.where((c) => c.value.enabled)) {
      final codec = _codec(connection.value.coreId);
      final useDevice =
          codec is DeviceGrantPolicy &&
          (codec as DeviceGrantPolicy).requiresDeviceGrant(connection);
      final owner = useDevice ? recipientId : recipient.parentId ?? recipientId;
      yield* data.grants.where(
        (g) => g.recipientId == owner && g.connectionId == connection.value.id,
      );
    }
  }

  List<ClientEndpoint> _clientEndpoints(PanelData data, String recipientId) {
    return [
      for (final grant in _grants(data, recipientId)) _endpoint(data, grant),
    ];
  }

  ClientEndpoint _endpoint(PanelData data, AccessGrant grant) {
    final connection = data.connections.firstWhere(
      (c) => c.value.id == grant.connectionId,
    );
    return _codec(
      connection.value.coreId,
    ).clientEndpoint(connection, grant, data.address);
  }

  Future<void> _canExport(
    String recipientId, {
    Set<String>? connectionIds,
  }) async {
    if (busy) throw const ApiException('configuration_busy', status: 503);
    if (!await isSynchronized())
      throw const ApiException('configuration_out_of_sync', status: 503);
    final data = repository.read();
    final granted = _grants(
      data,
      recipientId,
    ).map((g) => g.connectionId).toSet();
    final owned = data.connections
        .where(
          (c) =>
              c.value.enabled &&
              (connectionIds == null || connectionIds.contains(c.value.id)) &&
              granted.contains(c.value.id),
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
    final data = repository.read();
    final user = data.recipients
        .where((u) => u.id == id && u.parentId == null)
        .firstOrNull;
    if (user == null || !user.enabled)
      throw const ApiException('not_found', status: 404);
    await _canExport(id);
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
    final endpoints = _clientEndpoints(data, id);
    if (endpoints.isEmpty) throw const ApiException('not_found', status: 404);
    if (format == 'relink') {
      await _canExport(id);
      return jsonEncode({
        'version': 1,
        'profiles': [
          for (final endpoint in endpoints)
            {
              'id': _relinkProfileId(data, endpoint.id),
              'name': endpoint.name,
              'protocol': endpoint.protocolId,
              'server': endpoint.server,
              'port': endpoint.port,
              if (endpoint.protocolId == 'amneziawg')
                'configuration': amneziaProfile(endpoint)
              else ...{
                'settings': endpoint.settings,
                'credentials': endpoint.credentials,
              },
            },
        ],
      });
    }
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
      for (final grant in _grants(data, id))
        if (selected.any(
          (endpoint) =>
              endpoint.id == grant.id || endpoint.id == grant.connectionId,
        ))
          grant.connectionId,
    };
    await _canExport(id, connectionIds: selectedIds);
    return switch (format) {
      'clash' => exporter.profile(selected),
      'v2ray' => V2RayExporter().profile(selected),
      _ => throw const ApiException('export_unavailable', status: 422),
    };
  });

  String _relinkProfileId(PanelData data, String grantId) {
    final grant = data.grants.where((g) => g.id == grantId).firstOrNull;
    if (grant == null) return grantId;
    final recipient = data.recipients.firstWhere(
      (u) => u.id == grant.recipientId,
    );
    if (recipient.parentId == null) return grantId;
    return data.grants
        .firstWhere(
          (g) =>
              g.recipientId == recipient.parentId &&
              g.connectionId == grant.connectionId,
        )
        .id;
  }
}
