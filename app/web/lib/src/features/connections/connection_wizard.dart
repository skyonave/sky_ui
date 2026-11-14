import 'dart:async';

import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:web/web.dart' as web;

import '../../shared/api/api_client.dart';
import '../../shared/components/field_help.dart';
import '../../shared/components/primitives.dart';
import '../../shared/forms/protocol_field.dart';
import '../../shared/localization/strings.dart';
import '../../shared/protocols/catalog.dart';
import '../../shared/state/panel_store.dart';
import '../engines/install_progress.dart';
import 'connection_draft.dart';
import 'route_engines.dart';
import 'sni_picker.dart';

class ConnectionWizard extends StatefulComponent {
  const ConnectionWizard({
    required this.api,
    required this.store,
    required this.revision,
    required this.initial,
    required this.canInspect,
    required this.canEdit,
    required this.dataBusy,
    required this.maintenanceBusy,
    required this.job,
    required this.coreInstalled,
    required this.onClose,
    required this.onSave,
    required this.onInstalled,
    required this.onMaintenance,
    required this.onJob,
    this.routeNodes = const {},
    super.key,
  });
  final ApiClient api;
  final PanelStore store;
  final int revision;
  final Connection? initial;
  final bool canInspect, canEdit, dataBusy, maintenanceBusy;
  final MaintenanceJob? job;
  final bool Function(String) coreInstalled;
  final void Function() onClose;
  final Future<bool> Function(int, Connection) onSave;
  final void Function(PanelSnapshot, List<CoreSnapshot>) onInstalled;
  final void Function(MaintenanceSnapshot) onMaintenance;
  final void Function(MaintenanceJob) onJob;
  final Map<String, String> routeNodes;
  @override
  State<ConnectionWizard> createState() => _ConnectionWizardState();
}

class _ConnectionWizardState extends State<ConnectionWizard> {
  final t = const AppStrings();
  late final model = ConnectionDraft(
    store: store,
    coreInstalled: coreInstalled,
    engineAllowed: engineAllowed,
  );
  void changeField(ProtocolField field, String value) =>
      setState(() => model.changeField(field, value));
  ApiClient get api => component.api;
  PanelStore get store => component.store;
  bool get canInspect => component.canInspect;
  bool get canEdit => component.canEdit;
  bool get dataBusy => component.dataBusy;
  bool get maintenanceBusy => component.maintenanceBusy;
  bool get canChooseRoute =>
      model.selectedProtocol != null &&
      (route.length == 1 ||
          NodeRouting.supportsProxyCascade(model.selectedCore)) &&
      store.definition(model.selectedCore!, model.selectedProtocol!).shareable;
  bool get canRemoteIngress =>
      engineAllowed(model.selectedCore!) &&
      (model.draft['security'] != 'TLS' ||
          model.draft['certificateSource'] == 'custom');
  List<String> get route => model.route;
  Map<String, NodeRouting> get routing => model.routing;
  String get routeId => model.routeId;
  late final routeEngines = ConnectionRouteEngines(
    localInstalled: (id) => component.coreInstalled(id),
  );
  bool routeLoading = false;
  String? routeLoadError;
  int routeGeneration = 0;
  bool engineAllowed(String id) => routeEngines.allows(route, id);
  bool coreInstalled(String id) => routeEngines.installed(route, id);
  bool get routeEngineUnavailable =>
      model.selectedCore != null &&
      !routeLoading &&
      routeLoadError == null &&
      !engineAllowed(model.selectedCore!);
  MaintenanceJob? maintenanceJob;
  String runtimeMessage(String code) {
    final key = 'runtime.error.$code';
    final value = t(key);
    return value == key ? t('runtime.error.internal_error') : value;
  }

  final generatingFields = <String>{}, generatedDrafts = <String>{};
  int fieldGeneration = 0, dependencyGeneration = 0;
  late int draftRevision;
  String? dependencyMessage, dependencyJobId;

  bool dependencyBusy = false, dependencyReconnecting = false;

  @override
  void initState() {
    super.initState();
    draftRevision = component.revision;
    maintenanceJob = component.job;
    initialize(component.initial);
    if (route.first != Connection.localNode) unawaited(loadRouteEngines());
  }

  @override
  void dispose() {
    dependencyGeneration++;
    fieldGeneration++;
    routeGeneration++;
    super.dispose();
  }

  void initialize(Connection? connection) {
    model.editingId = connection?.id;
    model.route = connection?.route.isNotEmpty == true
        ? [...connection!.route]
        : [Connection.localNode];
    model.routing = {...?connection?.routing};
    model.routeId = connection?.routeId ?? '';
    dependencyGeneration++;
    model.connectionStep = connection == null ? 'route' : 'parameters';
    dependencyMessage = null;
    dependencyJobId = null;
    dependencyReconnecting = false;
    model.connectionErrors = {};
    model.advancedGroups.clear();
    generatingFields.clear();
    generatedDrafts.clear();
    fieldGeneration++;
    model.selectedProtocol = connection?.protocolId;
    model.selectedCore = connection?.coreId;
    model.draft = connection == null
        ? {'name': '', 'port': ''}
        : {
            'name': connection.name,
            'port': '${connection.port}',
            ...connection.settings,
            for (final key in connection.configuredSecrets)
              '_stored:$key': 'true',
          };
    if (connection != null) {
      for (final f in store.protocol(connection.protocolId).fields) {
        model.draft.putIfAbsent(f.id, () => f.defaultValue);
      }
    }
  }

  void chooseCore(String coreId) {
    if (!store.supports(coreId, model.selectedProtocol)) return;
    setState(() {
      model.selectedCore = coreId;
      generatingFields.clear();
      fieldGeneration++;
      model.connectionErrors = {};
      final definition = store.definition(coreId, model.selectedProtocol!);
      model.draft = definition.defaults({
        for (final f in definition.fields)
          if (model.draft[f.id] != null) f.id: model.draft[f.id]!,
        'name': model.draft['name'] ?? '',
        'port': model.draft['port'] ?? '',
        for (final entry in model.draft.entries)
          if (entry.key.startsWith('_stored:')) entry.key: entry.value,
        if (route.first != Connection.localNode &&
            definition.fields.any((f) => f.id == 'certificateSource'))
          'certificateSource': 'custom',
      });
      model.connectionStep = coreInstalled(coreId) ? 'core' : 'dependency';
      if (coreInstalled(coreId)) model.advanceConnection();
      model.error = null;
    });
    if (model.editingId == null &&
        generatedDrafts.add('$coreId:${model.selectedProtocol}')) {
      unawaited(generateConnectionFields('defaults'));
    }
  }

  Future<void> generateConnectionFields(String field) async {
    final core = model.selectedCore, protocol = model.selectedProtocol;
    if (core == null ||
        protocol == null ||
        generatingFields.isNotEmpty ||
        dataBusy)
      return;
    if (route.first != Connection.localNode && routeId.isEmpty) {
      setState(() => model.error = runtimeMessage('route_not_found'));
      return;
    }
    final generation = ++fieldGeneration;
    final before = Map<String, String>.from(model.draft);
    setState(() => generatingFields.add(field));
    try {
      final patch = await api.generateConnectionFields(
        draftRevision,
        core,
        protocol,
        field,
        before,
        routeId: routeId,
      );
      if (!mounted || generation != fieldGeneration) return;
      // Never overwrite input edited while the request was in flight.
      if (patch.keys.any((key) => model.draft[key] != before[key])) return;
      setState(() {
        model.draft.addAll(patch);
        for (final key in patch.keys) {
          model.connectionErrors.remove(key);
        }
      });
    } on ApiClientException catch (failure) {
      if (mounted && generation == fieldGeneration)
        setState(() => model.error = runtimeMessage(failure.code));
    } finally {
      if (mounted && generation == fieldGeneration)
        setState(() => generatingFields.remove(field));
    }
  }

  void chooseProtocol(ProtocolDefinition protocol) {
    final candidates = model.candidateEngines(protocol.id);
    if (candidates.isEmpty) return;
    setState(() {
      model.selectedProtocol = protocol.id;
      model.selectedCore = null;
      fieldGeneration++;
      generatingFields.clear();
      model.connectionErrors = {};
      model.advancedGroups.clear();
      model.connectionStep = 'core';
    });
    if (candidates.length == 1) chooseCore(candidates.single);
    Timer(const Duration(milliseconds: 30), () {
      (web.document.querySelector('#field-name') as web.HTMLElement?)?.focus();
    });
  }

  Future<void> saveConnection() async {
    if (model.selectedCore == null ||
        model.selectedProtocol == null ||
        !canEdit ||
        generatingFields.isNotEmpty)
      return;
    if (!store.supports(model.selectedCore, model.selectedProtocol)) {
      setState(() => model.error = t('protocol.unavailable'));
      return;
    }
    final definition = store.definition(
      model.selectedCore!,
      model.selectedProtocol!,
    );
    final name = model.draft['name']?.trim() ?? '';
    final port = int.tryParse(model.draft['port'] ?? '');
    if (name.isEmpty ||
        (definition.usesPort && (port == null || port < 1 || port > 65535))) {
      setState(
        () => model.error = t(
          name.isEmpty ? 'common.invalidName' : 'common.invalidPort',
        ),
      );
      return;
    }
    if (definition.validateFields(model.draft).isNotEmpty) {
      setState(() => model.error = t('common.required'));
      return;
    }
    final old = store.connections
        .where((c) => c.id == model.editingId)
        .firstOrNull;
    final selectedRoute =
        !(route.length == 1 && route.single == Connection.localNode)
        ? route
        : const <String>[];
    if (selectedRoute.isNotEmpty &&
        (!canChooseRoute ||
            selectedRoute.first != Connection.localNode && !canRemoteIngress)) {
      setState(
        () => model.error = t('runtime.error.route_protocol_unsupported'),
      );
      return;
    }
    if (routing.entries.any((entry) {
      final allowed = route.skip(route.indexOf(entry.key) + 1).toSet();
      bool invalidAction(String action) =>
          action.startsWith(NodeRouting.nodePrefix) &&
          !allowed.contains(action.substring(NodeRouting.nodePrefix.length));
      return invalidAction(entry.value.fallback) ||
          entry.value.rules.any(
            (rule) => rule.target.trim().isEmpty || invalidAction(rule.action),
          );
    })) {
      setState(() {
        model.connectionStep = 'parameters';
        model.error = t('runtime.error.route_policy_invalid');
      });
      return;
    }
    if (!coreInstalled(model.selectedCore!)) {
      setState(() {
        model.connectionStep = 'dependency';
      });
      return;
    }
    final value = Connection(
      id: model.editingId ?? '',
      name: name,
      coreId: model.selectedCore!,
      protocolId: model.selectedProtocol!,
      port: port,
      instanceId:
          old?.instanceId ?? store.instanceIds[model.selectedCore] ?? 'primary',
      enabled: old?.enabled ?? true,
      route: selectedRoute,
      routeId: routeId,
      routing: routing,
      settings: {
        for (final f in definition.activeFields(model.draft))
          f.id: model.draft[f.id] ?? f.initialValue(model.draft),
      },
    );
    try {
      await component.onSave(draftRevision, value);
    } on ApiClientException catch (e) {
      if (!mounted) return;
      setState(() {
        model.error = runtimeMessage(e.code);
        if (e.fields.isNotEmpty) {
          model.connectionErrors = e.fields;
          model.connectionStep = 'parameters';
        }
        if (e.code == 'route_policy_invalid') {
          model.connectionStep = 'parameters';
        }
      });
    }
  }

  Future<void> installDependency() async {
    if (dependencyBusy || model.selectedCore == null) return;
    if (route.first != Connection.localNode) {
      await installRemoteDependency();
      return;
    }
    final core = model.selectedCore!, protocol = model.selectedProtocol;
    final generation = ++dependencyGeneration;
    bool current() =>
        mounted &&
        generation == dependencyGeneration &&
        model.selectedCore == core &&
        model.selectedProtocol == protocol;
    setState(() {
      dependencyBusy = true;
      model.error = null;
      dependencyMessage = t('builder.installChecking');
    });
    try {
      final update = await api.updates(core);
      if (!current()) return;
      if (!update.available || update.versions.isEmpty)
        throw const ApiClientException('core_release_unverified');
      final job = await api.maintain(
        'install',
        core: core,
        tag: update.versions.first,
      );
      if (!current()) return;
      setState(() {
        maintenanceJob = job;
        component.onJob(job);
        dependencyJobId = job.id;
        dependencyReconnecting = false;
        dependencyMessage = t(
          core == 'amneziawg' ? 'builder.installingAwg' : 'builder.installing',
        );
      });
      final deadline = DateTime.now().add(const Duration(minutes: 12));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 1));
        if (!current()) return;
        MaintenanceSnapshot status;
        try {
          status = await api.maintenance();
        } on ApiClientException catch (e) {
          if (e.code == 'auth_required') rethrow;
          if (current()) setState(() => dependencyReconnecting = true);
          continue; // The maintenance worker briefly stops the API while installing.
        }
        if (!current()) return;
        setState(() {
          component.onMaintenance(status);
          maintenanceJob = status.job;
          dependencyReconnecting = false;
        });
        if (status.job?.id != job.id || status.job!.busy) continue;
        if (status.job!.status != 'completed')
          throw ApiClientException(status.job!.error ?? 'maintenance_failed');
        final snapshots = await api.cores();
        final data = await api.panel();
        if (!current()) return;
        setState(() {
          component.onInstalled(data, snapshots);
          draftRevision = data.revision;
          dependencyMessage = null;
        });
        chooseCore(core);
        return;
      }
      throw const ApiClientException('maintenance_timeout');
    } on ApiClientException catch (e) {
      if (current()) setState(() => model.error = runtimeMessage(e.code));
    } finally {
      if (current()) setState(() => dependencyBusy = false);
    }
  }

  Future<void> installRemoteDependency() async {
    final node = route.first, core = model.selectedCore!;
    final generation = ++dependencyGeneration;
    bool current() => mounted && generation == dependencyGeneration;
    setState(() {
      dependencyBusy = true;
      dependencyMessage = t('builder.installing');
      model.error = null;
    });
    try {
      await api.installServerEngine(node, core);
      final inventory = await api.serverEngines(node);
      if (!current()) return;
      setState(() {
        routeEngines.update(node, inventory);
        dependencyMessage = null;
      });
      if (!coreInstalled(core)) {
        throw const ApiClientException('core_not_ready');
      }
      chooseCore(core);
    } on ApiClientException catch (failure) {
      if (current()) {
        setState(() {
          dependencyMessage = null;
          model.error = runtimeMessage(failure.code);
        });
      }
    } finally {
      if (current()) setState(() => dependencyBusy = false);
    }
  }

  Component connectionForm() {
    if (model.connectionStep == 'route') return routeFields();
    if (model.connectionStep == 'protocol')
      return div([
        div([
          for (final protocol in productProtocols)
            productProtocolCard(protocol),
        ], classes: 'protocol-grid'),
      ]);
    if (model.connectionStep == 'core')
      return div([
        div([
          for (final id in model.candidateEngines(model.selectedProtocol!))
            button(
              [
                icon('core'),
                txt(coreName(id)),
                if (id == model.candidateEngines(model.selectedProtocol!).first)
                  txt(t('builder.recommended'), classes: 'recommended-badge'),
                txt(
                  t(
                    coreInstalled(id)
                        ? 'builder.engineInstalled'
                        : 'builder.engineRequired',
                  ),
                  classes: 'muted small',
                ),
              ],
              classes: 'protocol-option core-option',
              type: ButtonType.button,
              disabled: dataBusy || dependencyBusy,
              onClick: () => chooseCore(id),
            ),
        ], classes: 'protocol-grid core-grid'),
      ]);
    if (model.connectionStep == 'dependency')
      return div([
        h3([Component.text(coreName(model.selectedCore!))]),
        if (route.first != Connection.localNode)
          p([txt(nodeLabel(route.first))], classes: 'muted small'),
        p([Component.text(t('builder.installRequired'))]),
        if (dependencyMessage != null) p([Component.text(dependencyMessage!)]),
        if (route.first != Connection.localNode && dependencyBusy)
          div(
            [div([], classes: 'update-progress-fill indeterminate')],
            classes: 'update-progress',
            attributes: {
              'role': 'progressbar',
              'aria-label': t('builder.installing'),
            },
          ),
        if (route.first == Connection.localNode &&
            (dependencyBusy ||
                (dependencyJobId != null &&
                    maintenanceJob?.id == dependencyJobId) ||
                maintenanceJob?.core == model.selectedCore &&
                    ['install', 'update'].contains(maintenanceJob?.action)))
          CoreInstallProgress(
            core: model.selectedCore!,
            job:
                (dependencyJobId != null &&
                        maintenanceJob?.id == dependencyJobId) ||
                    maintenanceJob?.core == model.selectedCore
                ? maintenanceJob
                : null,
            busy: dependencyBusy || maintenanceJob?.busy == true,
            reconnecting: dependencyReconnecting,
          ),
        action(
          t(dependencyBusy ? 'builder.installing' : 'builder.installContinue'),
          () => coreInstalled(model.selectedCore!)
              ? setState(() => chooseCore(model.selectedCore!))
              : unawaited(installDependency()),
          classes: 'button primary',
          disabled: dependencyBusy || maintenanceBusy,
        ),
      ], classes: 'builder-content');
    final definition = store.definition(
      model.selectedCore!,
      model.selectedProtocol!,
    );
    final fields = definition
        .activeFields(model.draft)
        .where(
          (f) => model.connectionStep == 'parameters'
              ? !model.isStepChoice(f, definition)
              : f.group == model.connectionStep &&
                    model.isStepChoice(f, definition),
        )
        .toList();
    return div([
      div([
        txt(coreName(model.selectedCore!), classes: 'protocol-tag'),
        txt(definition.name, classes: 'protocol-tag'),
        for (final id in ['transport', 'security'])
          if (model.draft[id]?.isNotEmpty == true)
            txt(model.draft[id]!, classes: 'protocol-tag'),
      ], classes: 'selected-protocol'),
      for (final restriction in definition.exportRestrictions.where(
        (r) => r.matches(definition.clientValues(model.draft)),
      ))
        p([
          Component.text(t(restriction.reasonKey)),
        ], classes: 'builder-notice'),
      if (model.connectionStep == 'review' &&
          definition.deliveryHintKey != null)
        p([
          Component.text(t(definition.deliveryHintKey!)),
        ], classes: 'muted small'),
      if (model.connectionStep == 'review') ...[
        h3([
          Component.text(t('builder.review')),
        ], classes: 'form-section-title'),
        el('dl', [
          for (final entry in <String, String>{
            t('field.name'): model.draft['name'] ?? '',
            t('builder.address'): store.addressForNode(route.first).isEmpty
                ? t('builder.route.addressUnavailable')
                : store.endpointForNode(
                    route.first,
                    definition.usesPort
                        ? int.tryParse(model.draft['port'] ?? '')
                        : null,
                  ),
            t('builder.route'): route.map(nodeLabel).join(' / '),
            if (routing.isNotEmpty)
              t('routing.title'): t('routing.review', {
                'nodes': routing.length,
                'rules': routing.values.fold<int>(
                  0,
                  (total, p) => total + p.rules.length,
                ),
              }),
            for (final f
                in definition
                    .activeFields(model.draft)
                    .where(
                      (f) =>
                          !f.advanced && (model.draft[f.id] ?? '').isNotEmpty,
                    ))
              t(f.labelKey): f.secret ? '••••••••' : model.draft[f.id]!,
          }.entries)
            div([
              el('dt', [Component.text(entry.key)]),
              el('dd', [Component.text(entry.value)]),
            ], classes: 'review-row'),
        ], classes: 'connection-review'),
        p([
          Component.text(
            t(
              !definition.shareable
                  ? 'builder.systemInput'
                  : definition.isolatedBindings
                  ? 'builder.isolatedPorts'
                  : 'builder.credentialsAuto',
            ),
          ),
        ], classes: 'muted small'),
      ] else ...[
        if (model.connectionStep == 'parameters') ...[
          h3([
            Component.text(t('modal.general')),
          ], classes: 'form-section-title'),
          div([
            field(const ProtocolField('name', required: true, maxLength: 80)),
            if (definition.usesPort)
              field(
                const ProtocolField(
                  'port',
                  generator: 'port',
                  kind: 'integer',
                  minimum: 1,
                  maximum: 65535,
                  required: true,
                ),
              ),
          ], classes: 'form-grid'),
        ],
        for (final f in fields.where((f) => f.kind == 'choice' && !f.advanced))
          field(f),
        div([
          for (final f in fields.where(
            (f) => f.kind != 'choice' && !f.advanced,
          ))
            field(f),
        ], classes: 'form-grid'),
        if (fields.any((f) => f.advanced)) ...[
          action(
            t('builder.advancedCount', {
              'count': fields.where((f) => f.advanced).length,
            }),
            () => setState(() {
              if (!model.advancedGroups.add(model.connectionStep))
                model.advancedGroups.remove(model.connectionStep);
            }),
            glyph: 'chevron',
            classes: 'button ghost advanced-toggle',
          ),
          if (model.advancedGroups.contains(model.connectionStep))
            div([
              for (final f in fields.where((f) => f.advanced)) field(f),
            ], classes: 'form-grid'),
        ],
      ],
    ], classes: 'builder-content');
  }

  bool routeCompatible(NamedRoute value) {
    if (model.editingId == null || model.selectedCore == null) return true;
    return value.nodes.length == 1 ||
        NodeRouting.supportsProxyCascade(model.selectedCore);
  }

  String nodeLabel(String node) => node == Connection.localNode
      ? store.serverName
      : component.routeNodes[node] ?? node;

  void chooseRoute(NamedRoute? selected) {
    setState(() {
      routeGeneration++;
      routeLoading = false;
      routeLoadError = null;
      fieldGeneration++;
      generatingFields.clear();
      model.selectRoute(selected);
      if (route.first != Connection.localNode &&
          model.draft.containsKey('certificateSource')) {
        model.draft['certificateSource'] = 'custom';
      }
    });
    if (route.first != Connection.localNode) unawaited(loadRouteEngines());
  }

  Future<void> loadRouteEngines() async {
    final node = route.first;
    if (node == Connection.localNode) return;
    final generation = ++routeGeneration;
    bool current() => mounted && generation == routeGeneration;
    setState(() {
      routeLoading = true;
      routeLoadError = null;
    });
    try {
      final inventory = await api.serverEngines(node);
      if (!current()) return;
      setState(() {
        routeEngines.update(node, inventory);
      });
    } on ApiClientException catch (failure) {
      if (current()) {
        setState(() => routeLoadError = runtimeMessage(failure.code));
      }
    } finally {
      if (current()) setState(() => routeLoading = false);
    }
  }

  Component routeChoice(NamedRoute? value) {
    final nodes = value?.nodes ?? const [Connection.localNode];
    final selected = value == null
        ? routeId.isEmpty &&
              route.length == 1 &&
              route.single == Connection.localNode
        : routeId == value.id;
    final available = value == null || routeCompatible(value);
    return button(
      [
        span([
          icon('server'),
          txt(value?.name ?? t('builder.route.local')),
          if (selected) icon('check'),
        ], classes: 'protocol-card-heading'),
        if (value == null)
          txt(t('builder.route.localDescription'), classes: 'muted small')
        else
          div([
            txt('${t('builder.route.ingress')}: ${nodeLabel(nodes.first)}'),
            txt('${t('builder.route.egress')}: ${nodeLabel(nodes.last)}'),
          ], classes: 'connection-route-summary'),
        if (store.addressForNode(nodes.first).isNotEmpty)
          txt(store.addressForNode(nodes.first), classes: 'mono muted small'),
        if (!available)
          txt(t('builder.route.incompatible'), classes: 'availability-chip'),
      ],
      classes:
          'protocol-option connection-route-choice ${selected ? 'selected' : ''}',
      type: ButtonType.button,
      attributes: {'aria-pressed': '$selected'},
      disabled: !canEdit || dependencyBusy || dataBusy || !available,
      onClick: () => chooseRoute(value),
    );
  }

  Component routeFields() => div([
    routeChoice(null),
    for (final value in store.routes) routeChoice(value),
  ], classes: 'connection-route-list');
  Component productProtocolCard(ProductProtocol protocol) {
    final available = model.candidateEngines(protocol.id).isNotEmpty;
    return div([
      button(
        [
          span([
            icon('connections'),
            txt(protocol.name),
            icon('chevron'),
          ], classes: 'protocol-card-heading'),
          span([
            Component.text(t(protocol.descriptionKey)),
          ], classes: 'protocol-description'),
          if (!available)
            txt(
              t(protocol.tentative ? 'builder.planned' : 'feature.unavailable'),
              classes: 'availability-chip',
            ),
        ],
        type: ButtonType.button,
        classes: 'protocol-select',
        disabled: dataBusy || !available,
        onClick: () => chooseProtocol(
          ProtocolDefinition(protocol.id, protocol.name, const []),
        ),
      ),
      FieldHelp(
        id: 'about-${protocol.id}',
        label: protocol.name,
        description: t(protocol.detailsKey),
        buttonLabel: t('common.help', {'name': protocol.name}),
        key: ValueKey('product:${protocol.id}'),
      ),
    ], classes: 'protocol-card ${available ? 'available' : 'unavailable'}');
  }

  Component field(ProtocolField f) {
    model.draft.putIfAbsent(f.id, () => f.initialValue(model.draft));
    final original = store.connections
        .where((c) => c.id == model.editingId)
        .firstOrNull;
    return ProtocolFieldView(
      field: f,
      values: model.draft,
      error: model.connectionErrors[f.id],
      busy: dataBusy || generatingFields.isNotEmpty,
      onGenerate: f.generator == null
          ? null
          : () => generateConnectionFields(f.id),
      extra:
          route.first == Connection.localNode &&
              f.id == 'serverName' &&
              model.draft['security'] == 'REALITY'
          ? SniPicker(
              api: api,
              revision: draftRevision,
              onSelected: (domain) {
                setState(() {
                  model.draft['serverName'] = domain;
                  final fields = store
                      .definition(model.selectedCore!, model.selectedProtocol!)
                      .fields;
                  if (fields.any((f) => f.id == 'realityTarget'))
                    model.draft['realityTarget'] = '$domain:443';
                  if (fields.any((f) => f.id == 'handshakePort'))
                    model.draft['handshakePort'] = '443';
                });
              },
              key: ValueKey(
                'sni:${model.selectedCore}:${model.selectedProtocol}:${model.editingId}',
              ),
            )
          : null,
      prefix: '${model.selectedCore}-${model.selectedProtocol}-',
      configured: original?.configuredSecrets.contains(f.id) == true,
      blockedOptions: {
        ...model.blockedChoices(f),
        if (route.first != Connection.localNode && f.id == 'certificateSource')
          'panel': 'builder.route.remoteCertificate',
      },
      guideScope: model.selectedProtocol ?? '',
      onChanged: (value, rebuild) {
        if (rebuild) {
          changeField(f, value);
        } else {
          model.draft[f.id] = value;
          if (model.connectionErrors.containsKey(f.id))
            setState(() => model.connectionErrors.remove(f.id));
        }
      },
      key: ValueKey(
        'field:${model.selectedCore}:${model.selectedProtocol}:${f.id}',
      ),
    );
  }

  @override
  Component build(BuildContext context) => div([
    div(
      [
        div([
          div([
            h2([
              Component.text(
                t(model.editingId == null ? 'modal.new' : 'modal.edit'),
              ),
            ], id: 'modal-title'),
            div([
              for (final step in model.connectionSteps)
                button(
                  [Component.text(t('builder.step.$step'))],
                  classes:
                      'step-button ${step == model.connectionStep
                          ? 'active'
                          : model.connectionSteps.indexOf(step) < model.connectionSteps.indexOf(model.connectionStep)
                          ? 'complete'
                          : ''}',
                  type: ButtonType.button,
                  disabled:
                      dataBusy ||
                      dependencyBusy ||
                      model.connectionSteps.indexOf(step) >
                          model.connectionSteps.indexOf(model.connectionStep) ||
                      model.editingId != null &&
                          (step == 'core' || step == 'protocol'),
                  onClick: () => setState(() {
                    model.connectionStep = step;
                    model.connectionErrors = {};
                    model.error = null;
                  }),
                ),
            ], classes: 'steps builder-steps'),
          ]),
          iconButton(
            'close',
            t('common.close'),
            component.onClose,
            classes: 'icon-button modal-close',
            disabled: dataBusy,
          ),
        ], classes: 'modal-header'),
        div([
          connectionForm(),
          if (routeLoading)
            p(
              [txt(t('builder.route.checking'))],
              attributes: {'role': 'status'},
            ),
          if (routeLoadError != null) ...[
            p(
              [txt(routeLoadError!)],
              classes: 'form-error',
              attributes: {'role': 'alert'},
            ),
            action(t('common.retry'), () => unawaited(loadRouteEngines())),
          ],
          if (routeEngineUnavailable)
            p([txt(t('builder.route.incompatible'))], classes: 'form-error'),
          if (model.error != null)
            div(
              [icon('info'), Component.text(model.error!)],
              classes: 'form-error',
              attributes: {'role': 'alert'},
            ),
        ], classes: 'modal-body'),
        div([
          if (model.connectionSteps.indexOf(model.connectionStep) > 0 &&
              model.editingId == null)
            action(
              t('common.back'),
              () => setState(() {
                final previous =
                    model.connectionSteps.indexOf(model.connectionStep) - 1;
                if (previous >= 0)
                  model.connectionStep = model.connectionSteps[previous];
                model.connectionErrors = {};
                model.error = null;
              }),
              classes: 'button ghost',
              disabled: dataBusy || dependencyBusy,
            ),
          div([
            action(t('common.cancel'), component.onClose, disabled: dataBusy),
            if (model.connectionStep == 'route' ||
                model.selectedCore != null &&
                    !{
                      'core',
                      'protocol',
                      'dependency',
                    }.contains(model.connectionStep))
              action(
                t(
                  model.connectionStep == 'review'
                      ? (model.editingId == null
                            ? 'common.create'
                            : 'common.save')
                      : 'builder.next',
                ),
                model.connectionStep == 'review'
                    ? saveConnection
                    : () => setState(model.advanceConnection),
                classes: 'button primary',
                disabled:
                    dataBusy ||
                    dependencyBusy ||
                    routeLoading ||
                    routeLoadError != null ||
                    routeEngineUnavailable ||
                    (model.connectionStep == 'review'
                        ? !canEdit
                        : !canInspect) ||
                    model.connectionStep != 'route' &&
                        !store.supports(
                          model.selectedCore,
                          model.selectedProtocol,
                        ),
              ),
          ], classes: 'modal-footer-actions'),
        ], classes: 'modal-footer'),
      ],
      classes: 'modal wide',
      attributes: {
        'role': 'dialog',
        'aria-modal': 'true',
        'aria-labelledby': 'modal-title',
      },
    ),
  ], classes: 'modal-overlay');
}
