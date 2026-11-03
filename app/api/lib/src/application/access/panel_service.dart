import 'dart:io';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/api_exception.dart';
import '../configuration/transaction.dart';
import '../connections/field_generators.dart';
import '../contracts/access_environment.dart';
import '../contracts/configuration_codec.dart';
import '../contracts/configuration_store.dart';
import '../engines/core_manager.dart';
import '../engines/registry.dart';
import '../subscriptions/client_exporter.dart';
import '../subscriptions/subscription_service.dart';
import 'connection_commands.dart';
import 'recipient_commands.dart';
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
  );
  bool get busy => deployment.busy;
  late final subscriptions = SubscriptionService(
    config: config,
    registry: registry,
    repository: repository,
    exporter: exporter,
    isBusy: () => busy,
    isSynchronized: isSynchronized,
  );
  late final connectionCommands = ConnectionCommands(
    config: config,
    registry: registry,
    portProbe: portProbe,
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
    data.serverName = validatedName(name);
    data.address = address.trim();
  });

  Future<RecipientShare> share(String id) => subscriptions.share(id);
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
