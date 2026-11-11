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
      component.routeNodes.length > 1 &&
      model.selectedProtocol == 'vless' &&
      model.selectedCore == 'mihomo';
  List<String> route = [Connection.localNode];
  bool forceLocalInstall = false;
  bool coreInstalled(String id) =>
      component.coreInstalled(id) ||
      id == 'mihomo' && canChooseRoute && !forceLocalInstall;
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
  }

  @override
  void dispose() {
    dependencyGeneration++;
    fieldGeneration++;
    super.dispose();
  }

  void initialize(Connection? connection) {
    model.editingId = connection?.id;
    route = connection?.route.isNotEmpty == true
        ? [...connection!.route]
        : [Connection.localNode];
    dependencyGeneration++;
    model.connectionStep = connection == null ? 'protocol' : 'parameters';
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
      route = [Connection.localNode];
      forceLocalInstall = false;
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
        canChooseRoute &&
            !(route.length == 1 && route.single == Connection.localNode)
        ? route
        : const <String>[];
    if (selectedRoute.isNotEmpty &&
        (model.draft['transport'] != 'TCP' ||
            model.draft['security'] != 'REALITY')) {
      setState(
        () => model.error = t('runtime.error.route_protocol_unsupported'),
      );
      return;
    }
    if (canChooseRoute &&
        (selectedRoute.isEmpty ||
            selectedRoute.contains(Connection.localNode)) &&
        !component.coreInstalled(model.selectedCore!)) {
      setState(() {
        forceLocalInstall = true;
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
      });
    }
  }

  Future<void> installDependency() async {
    if (dependencyBusy || model.selectedCore == null) return;
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

  Component connectionForm() {
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
        p([Component.text(t('builder.installRequired'))]),
        if (dependencyMessage != null) p([Component.text(dependencyMessage!)]),
        if (dependencyBusy ||
            (dependencyJobId != null &&
                maintenanceJob?.id == dependencyJobId) ||
            maintenanceJob?.core == model.selectedCore &&
                ['install', 'update'].contains(maintenanceJob?.action))
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
            if (!canChooseRoute || route.first == Connection.localNode)
              t('builder.address'): definition.usesPort
                  ? '${store.address}:${model.draft['port']}'
                  : store.address,
            if (canChooseRoute)
              t('builder.route'): route
                  .map((node) => component.routeNodes[node] ?? node)
                  .join(' → '),
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
          if (canChooseRoute) routeFields(),
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

  Component routeFields() => div([
    h3([txt(t('builder.route'))], classes: 'form-section-title'),
    for (var i = 0; i < route.length; i++) routeField(i),
    if (route.length < 8 && route.length < component.routeNodes.length)
      action(
        t('builder.routeAdd'),
        () => setState(() {
          route.add(
            component.routeNodes.keys.firstWhere((id) => !route.contains(id)),
          );
        }),
        glyph: 'plus',
        disabled: !canEdit,
      ),
    p([txt(t('builder.routeHelp'))], classes: 'muted small'),
  ]);

  Component routeField(int index) => div([
    label([
      txt(
        t(
          index == 0
              ? 'builder.routeIngress'
              : index == route.length - 1
              ? 'builder.routeEgress'
              : 'builder.routeTransit',
        ),
      ),
      select(
        [
          for (final entry in component.routeNodes.entries)
            if (entry.key == route[index] || !route.contains(entry.key))
              option([txt(entry.value)], value: entry.key),
        ],
        value: route[index],
        disabled: !canEdit,
        onChange: (values) {
          if (values.isNotEmpty) setState(() => route[index] = values.single);
        },
      ),
    ]),
    if (route.length > 1)
      iconButton(
        'trash',
        t('builder.routeRemove'),
        () => setState(() => route.removeAt(index)),
        disabled: !canEdit,
      ),
  ], classes: 'route-field');

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
      extra: f.id == 'serverName' && model.draft['security'] == 'REALITY'
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
      blockedOptions: model.blockedChoices(f),
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
              disabled: dataBusy,
            ),
          div([
            action(t('common.cancel'), component.onClose, disabled: dataBusy),
            if (model.selectedCore != null &&
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
                    (model.connectionStep == 'review'
                        ? !canEdit
                        : !canInspect) ||
                    !store.supports(model.selectedCore, model.selectedProtocol),
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
