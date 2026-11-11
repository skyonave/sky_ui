import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/api_exception.dart';
import '../configuration/transaction.dart';
import '../configuration/relay_routes.dart';
import '../configuration/route_policy.dart';
import '../connections/field_generators.dart';
import '../contracts/access_environment.dart';
import '../contracts/configuration_codec.dart';
import '../contracts/configuration_store.dart';
import '../engines/core_manager.dart';
import '../engines/registry.dart';
import '../logs/panel_log.dart';
import '../subscriptions/client_exporter.dart';
import '../subscriptions/subscription_service.dart';
import 'connection_commands.dart';
import 'recipient_commands.dart';
import 'recipient_presence.dart';
import 'records.dart';
import 'repository.dart';
import 'validation.dart';

class PanelService {
  PanelService({
    required this.config,
    required this.manager,
    required this.repository,
    required this.configurationStore,
    required Map<String, ConfigurationCodec> codecs,
    required this.exporter,
    this.portProbe = connectionPortAvailable,
    this.routes,
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
  final AccessEnvironment config;
  final Future<bool> Function(int) portProbe;
  final CoreManager manager;
  final AccessRepository repository;
  final ConfigurationStore configurationStore;
  final RelayRoutes? routes;
  final log = PanelLog();
  final Map<String, ConfigurationCodec> codecs;
  final Map<String, CoreManager> managers;
  ConfigurationCodec get codec => codecs[manager.core.coreId]!;
  ConfigurationCodec _codec(String id) => registry.codec(id);

  Future<T> _exclusive<T>(
    Future<T> Function(Map<String, CoreControl>) action,
  ) => registry.exclusive(action);

  final ClientExporter exporter;
  final Map<String, ClientExporter> exporters;
  late final registry = EngineRegistry(
    primary: manager,
    managers: managers,
    codecs: codecs,
  );
  late final deployment = ConfigurationTransaction(
    registry: registry,
    repository: repository,
    files: configurationStore,
    log: log,
    routes: routes,
  );
  bool get busy => deployment.busy;
  late final presence = RecipientPresenceService(
    repository,
    managers,
    () async => !busy && await isSynchronized(),
  );
  late final subscriptions = SubscriptionService(
    config: config,
    registry: registry,
    repository: repository,
    exporter: exporter,
    isBusy: () => busy,
    isSynchronized: isSynchronized,
    routes: routes,
  );
  late final connectionCommands = ConnectionCommands(
    config: config,
    registry: registry,
    portProbe: portProbe,
    routes: routes,
  );
  late final recipientCommands = RecipientCommands(
    config: config,
    registry: registry,
  );

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

  Future<void> initialize() => deployment.initialize();

  Future<bool> isSynchronized() => deployment.isSynchronized();

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
          ).verifyRunning(deployment.local(data, owner.core.id), owner.core);
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
      routeNodes: routes?.names(data) ?? const {},
      connections: data.connections
          .map(
            (c) => c.value.copyWith(
              routePorts: [
                for (var i = 0; i < c.value.route.length - 1; i++)
                  int.parse(c.secrets['relay:port:$i']!),
              ],
              routeShortcuts: [
                for (final edge in RoutePolicy.edges(c.value))
                  if (edge.to > edge.from + 1)
                    RouteShortcut(
                      c.value.route[edge.from],
                      c.value.route[edge.to],
                      int.parse(c.secrets['relay:port:${edge.index}']!),
                    ),
              ],
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
      recipients: data.recipients
          .where((u) => u.parentId == null)
          .map(data.publicRecipient)
          .toList(),
      serverName: data.serverName,
      address: data.address,
      synchronized: synchronized,
      deliveryReady:
          readiness.values.any((v) => v) ||
          synchronized &&
              data.listeningConnections.any(
                (c) => c.value.ingress != Connection.localNode,
              ),
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
      errorCode: repository.pending != null
          ? 'configuration_rollback_failed'
          : !synchronized
          ? 'configuration_out_of_sync'
          : !core.binaryAvailable && !(routes?.allowNew ?? false)
          ? 'binary_missing'
          : readinessError,
    );
  }

  Future<void> _check(int revision) => deployment.checkRevision(revision);

  Future<PanelSnapshot> _change(
    int revision,
    Future<void> Function(PanelData) update,
  ) => deployment.apply(revision, update, _snapshot);

  Future<PanelSnapshot> saveConnection(
    int revision,
    Connection input, {
    String? id,
  }) =>
      _change(revision, (data) => connectionCommands.save(data, input, id: id));
  Future<PanelSnapshot> saveRouting(
    int revision,
    String id,
    String node,
    NodeRouting policy,
  ) => _change(
    revision,
    (data) => connectionCommands.saveRouting(data, id, node, policy),
  );
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
  }) =>
      _change(revision, (data) => recipientCommands.save(data, input, id: id));

  Future<PanelSnapshot> deleteRecipient(int revision, String id) =>
      _change(revision, (data) async {
        if (!data.recipients.any((u) => u.id == id && u.parentId == null))
          throw const ApiException('not_found', status: 404);
        final removed = {
          id,
          for (final user in data.recipients)
            if (user.parentId == id) user.id,
        };
        data.grants.removeWhere((g) => removed.contains(g.recipientId));
        data.recipients.removeWhere((u) => removed.contains(u.id));
      });
  Future<PanelSnapshot> saveSettings(
    int revision,
    String name,
    String address,
  ) => _change(revision, (data) async {
    if (!validAddress(address.trim()))
      throw const ApiException('address_invalid', status: 422);
    data.serverName = validatedName(name);
    data.address = address.trim();
  });

  Future<RecipientShare> share(String id) => subscriptions.share(id);

  Future<String> enrollSubscription(
    String token,
    String installation,
    String name,
  ) async {
    final parentId = repository.recipientForToken(token);
    if (parentId == null) throw const ApiException('not_found', status: 404);
    final deviceToken = base64Url
        .encode(
          Hmac(
            sha256,
            utf8.encode(token),
          ).convert(utf8.encode('sky-ui-device-v1:$installation')).bytes,
        )
        .replaceAll('=', '');
    StoredRecipient parentIn(PanelData data) {
      final parent = data.recipients
          .where((u) => u.id == parentId && u.parentId == null && u.enabled)
          .firstOrNull;
      if (parent == null) throw const ApiException('not_found', status: 404);
      return parent;
    }

    for (var attempt = 0; attempt < 5; attempt++) {
      final revision = repository.revision;
      final data = repository.read();
      parentIn(data);
      if (repository.recipientForToken(deviceToken) != null) return deviceToken;
      try {
        await deployment.apply(revision, (draft) async {
          final parent = parentIn(draft);
          await recipientCommands.enroll(
            draft,
            parent,
            StoredRecipient(
              id: newId('d'),
              name: validatedName(name),
              enabled: true,
              token: deviceToken,
              parentId: parent.id,
            ),
          );
        }, () async {});
        log.event('Subscription device registered');
        return deviceToken;
      } on ApiException catch (e) {
        if (e.code != 'state_changed') rethrow;
      }
    }
    throw const ApiException('state_changed', status: 409);
  }

  Future<String> subscription(
    String token, {
    String format = 'clash',
    String? clientId,
  }) => subscriptions.subscription(token, format: format, clientId: clientId);
  Future<CoreSnapshot> executeCore(
    CoreOperation operation, {
    String? instanceId,
  }) {
    final owner = managers[instanceId ?? manager.core.id];
    if (owner == null)
      throw const ApiException('instance_not_found', status: 404);
    return owner.exclusive((control) async {
      log.event('${owner.core.coreId} ${operation.name}');
      if ([CoreOperation.start, CoreOperation.restart].contains(operation) &&
          !await isSynchronized()) {
        throw const ApiException('configuration_out_of_sync', status: 409);
      }
      final result = await control.execute(operation);
      if ([CoreOperation.start, CoreOperation.restart].contains(operation)) {
        try {
          await _codec(owner.core.coreId).verifyRunning(
            deployment.local(repository.read(), owner.core.id),
            owner.core,
          );
        } on Object {
          await control.execute(CoreOperation.stop);
          rethrow;
        }
      }
      log.event('${owner.core.coreId} ${operation.name} completed');
      return result;
    });
  }

  Future<void> restoreCore() async {
    for (final owner in managers.values) {
      try {
        await owner.exclusive((control) async {
          final service = await owner.supervisor.inspect(owner.core);
          if (!service.loaded || !owner.supervisor.supported) return;
          if (owner.desired == CoreDesiredState.stopped) {
            if (service.state == CoreProcessState.active)
              await control.execute(CoreOperation.stop, remember: false);
            return;
          }
          if (service.state != CoreProcessState.inactive &&
              service.state != CoreProcessState.failed)
            return;
          final data = deployment.local(repository.read(), owner.core.id);
          if (owner.desired != CoreDesiredState.running &&
              data.listeningConnections.isEmpty &&
              !data.relays.any((link) => link.inbound))
            return;
          if (!(await owner.adapter.probe(owner.core)).available ||
              !await isSynchronized())
            return;
          final codec = _codec(owner.core.coreId);
          await codec.preflight(data, data, false);
          try {
            await control.execute(CoreOperation.start, remember: false);
            await codec.verifyRunning(data, owner.core);
          } on Object {
            await control.execute(CoreOperation.stop, remember: false);
            rethrow;
          }
        });
      } on Object {
        owner.event('core_state_restore_failed', level: 'error');
      }
    }
  }
}
