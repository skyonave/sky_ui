import 'dart:async';

import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/api/api_client.dart';
import '../../shared/components/page_helpers.dart';
import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';

class ServersPage extends StatefulComponent {
  const ServersPage({
    required this.api,
    required this.localName,
    this.routes = const [],
    super.key,
  });

  final ApiClient api;
  final String localName;
  final List<NamedRoute> routes;

  @override
  State<ServersPage> createState() => _ServersPageState();
}

class _ServersPageState extends State<ServersPage> {
  static const t = AppStrings();
  List<ServerNode> nodes = [];
  final states = <String, String>{};
  final logs = <String, String>{};
  bool? enabled;
  bool busy = false;
  bool adding = false;
  String? removeId;
  String? bootstrapId;
  String bootstrapUser = 'root';
  String bootstrapKey = '';
  String bootstrapPassword = '';
  bool usePassword = false;
  String? error;
  Map<String, String> fieldErrors = {};
  final nodeErrors = <String, String>{};
  final checked = <String, DateTime>{};
  String? activeNode, endpointId;
  String editedEndpoint = '';
  String name = '';
  String host = '';
  String port = '22';
  String hostKey = '';
  String endpoint = '';
  String relayAddress = '';

  @override
  void initState() {
    super.initState();
    unawaited(run(load));
  }

  Future<void> run(Future<void> Function() operation, {String? nodeId}) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      fieldErrors = {};
      activeNode = nodeId;
      if (nodeId != null) nodeErrors.remove(nodeId);
    });
    try {
      await operation();
    } on ApiClientException catch (failure) {
      fieldErrors = failure.fields;
      if (nodeId == null) {
        error = failure.code;
      } else {
        nodeErrors[nodeId] = failure.code;
      }
    } on Object {
      if (nodeId == null) {
        error = 'generic';
      } else {
        nodeErrors[nodeId] = 'generic';
      }
    } finally {
      if (mounted)
        setState(() {
          busy = false;
          activeNode = null;
        });
    }
  }

  Future<void> load() async {
    final result = await component.api.servers();
    enabled = result.enabled;
    nodes = result.nodes;
  }

  Future<void> add() async {
    final value = int.tryParse(port);
    if (value == null) {
      error = 'server_invalid';
      fieldErrors = {'port': 'port'};
      return;
    }
    final node = await component.api.addServer(
      name: name,
      host: host,
      port: value,
      hostKey: hostKey,
      endpoint: endpoint,
      relayAddress: relayAddress,
    );
    nodes = [...nodes, node]..sort((a, b) => a.name.compareTo(b.name));
    adding = false;
    name = host = hostKey = endpoint = relayAddress = '';
    port = '22';
  }

  Future<void> operate(ServerNode node, ServerOperation operation) async {
    if (operation != ServerOperation.logs) states.remove(node.id);
    final value = await component.api.serverOperation(node.id, operation);
    if (operation == ServerOperation.logs) {
      logs[node.id] = value;
    } else {
      states[node.id] = value;
      checked[node.id] = DateTime.now();
    }
  }

  Future<void> remove(String id) async {
    await component.api.removeServer(id);
    nodes = nodes.where((node) => node.id != id).toList();
    states.remove(id);
    logs.remove(id);
    removeId = null;
    checked.remove(id);
    nodeErrors.remove(id);
  }

  void closeBootstrap() {
    bootstrapId = null;
    bootstrapKey = '';
    bootstrapPassword = '';
  }

  Future<void> bootstrap(ServerNode node) async {
    try {
      await component.api.bootstrapServer(
        node.id,
        bootstrapUser,
        usePassword ? '' : bootstrapKey,
        usePassword ? bootstrapPassword : '',
      );
      closeBootstrap();
      await operate(node, ServerOperation.status);
    } finally {
      bootstrapKey = '';
      bootstrapPassword = '';
    }
  }

  @override
  Component build(BuildContext context) => div([
    heading(
      'servers',
      trailing: enabled == true && !adding
          ? action(
              t('servers.add'),
              () => setState(() => adding = true),
              glyph: 'plus',
              disabled: busy,
            )
          : null,
    ),
    if (error != null)
      p(
        [txt(errorMessage(error!))],
        classes: 'notice',
        attributes: {'role': 'alert'},
      ),
    div([
      h2([txt(component.localName)]),
      txt(t('servers.local'), classes: 'availability-chip'),
    ], classes: 'settings-panel server-panel'),
    if (enabled == false)
      p([txt(t('servers.disabled'))], classes: 'notice')
    else if (enabled == null && error == null)
      p([txt(t('runtime.loading'))])
    else if (enabled == null)
      action(t('servers.status'), () => unawaited(run(load)), disabled: busy),
    if (adding) addForm(),
    for (final node in nodes) serverCard(node),
  ]);

  String errorMessage(String code) {
    final key = 'servers.error.$code';
    final message = t(key);
    return message == key ? t('servers.error.generic') : message;
  }

  Component field(
    String key,
    String value,
    void Function(String) onInput, {
    required int maxLength,
    String? placeholder,
    String? hint,
  }) => label([
    txt(t('servers.$key')),
    input<String>(
      value: value,
      onInput: (value) {
        onInput(value);
        if (fieldErrors.containsKey(key))
          setState(() => fieldErrors.remove(key));
      },
      disabled: busy,
      attributes: {
        'maxlength': '$maxLength',
        'autocomplete': 'off',
        if (placeholder != null) 'placeholder': placeholder,
        if (fieldErrors.containsKey(key)) 'aria-invalid': 'true',
      },
    ),
    if (hint != null) span([txt(t(hint))], classes: 'muted small'),
    if (fieldErrors[key] case final code?)
      span([txt(t('servers.validation.$code'))], classes: 'field-error'),
  ]);

  Component addForm() => div([
    h2([txt(t('servers.add'))]),
    div([
      field('name', name, (value) => name = value, maxLength: 80),
      field(
        'host',
        host,
        (value) => host = value,
        maxLength: 253,
        placeholder: '203.0.113.10',
        hint: 'servers.hostHelp',
      ),
      field('port', port, (value) => port = value, maxLength: 5),
      field(
        'hostKey',
        hostKey,
        (value) => hostKey = value,
        maxLength: 1024,
        placeholder: 'ssh-ed25519 AAAAC3…',
        hint: 'servers.keyHelp',
      ),
      field(
        'endpoint',
        endpoint,
        (value) => endpoint = value,
        maxLength: 253,
        placeholder: 'de.example.com',
        hint: 'servers.endpointHelp',
      ),
      field(
        'relayAddress',
        relayAddress,
        (value) => relayAddress = value,
        maxLength: 45,
        hint: 'servers.relayHelp',
      ),
    ], classes: 'form-grid'),
    p([txt(t('servers.hostKeyHelp'))], classes: 'muted small'),
    el('code', [
      txt('cat /etc/ssh/ssh_host_ed25519_key.pub'),
    ], classes: 'server-public-key'),
    p([txt(t('servers.saveHelp'))], classes: 'muted small'),
    div([
      action(t('common.save'), () => unawaited(run(add)), disabled: busy),
      action(
        t('common.cancel'),
        () => setState(() => adding = false),
        disabled: busy,
      ),
    ], classes: 'server-actions'),
  ], classes: 'settings-panel server-panel');

  Component bootstrapForm(ServerNode node) => div([
    p([txt(t('servers.bootstrapHelp'))], classes: 'muted small'),
    div([
      field(
        'bootstrapUser',
        bootstrapUser,
        (v) => bootstrapUser = v,
        maxLength: 32,
      ),
      label([
        txt(t('servers.bootstrapAuth')),
        select(
          [
            option([txt(t('servers.bootstrapKey'))], value: 'key'),
            option([txt(t('servers.bootstrapPassword'))], value: 'password'),
          ],
          value: usePassword ? 'password' : 'key',
          disabled: busy,
          onChange: (values) => setState(() {
            usePassword = values.firstOrNull == 'password';
            bootstrapKey = '';
            bootstrapPassword = '';
          }),
        ),
      ]),
    ], classes: 'form-grid'),
    if (usePassword)
      label([
        txt(t('servers.bootstrapPassword')),
        input<String>(
          type: InputType.password,
          value: bootstrapPassword,
          onInput: (v) => bootstrapPassword = v,
          disabled: busy,
          attributes: {'autocomplete': 'off', 'maxlength': '512'},
        ),
      ])
    else
      label([
        txt(t('servers.bootstrapKey')),
        textarea(
          [txt(bootstrapKey)],
          onInput: (v) => bootstrapKey = v,
          disabled: busy,
          attributes: {'autocomplete': 'off', 'maxlength': '12288'},
        ),
      ]),
    div([
      action(
        t('servers.bootstrap'),
        () => unawaited(run(() => bootstrap(node), nodeId: node.id)),
        disabled: busy,
        classes: 'button primary',
      ),
      action(
        t('common.cancel'),
        () => setState(closeBootstrap),
        disabled: busy,
      ),
    ], classes: 'server-actions'),
  ]);

  Component serverCard(ServerNode node) => div(
    [
      div([
        h2([txt(node.name)]),
        txt('mihomo', classes: 'protocol-tag'),
        pill(
          t(
            activeNode == node.id
                ? 'servers.working'
                : nodeErrors.containsKey(node.id)
                ? 'servers.checkFailed'
                : 'servers.state.${states[node.id] ?? 'unknown'}',
          ),
          positive:
              activeNode != node.id &&
              !nodeErrors.containsKey(node.id) &&
              states[node.id] == 'active',
        ),
      ], classes: 'server-heading'),
      el('dl', [
        for (final e in {
          'SSH':
              '${node.host.contains(':') ? '[${node.host}]' : node.host}:${node.port}',
          t('servers.clientAddress'): node.endpoint ?? node.host,
          t('servers.relayAddressShort'): node.relayAddress ?? node.host,
          t(
            'servers.usedRoutes',
          ): '${component.routes.where((r) => r.nodes.contains(node.id)).length}',
        }.entries)
          div([
            el('dt', [txt(e.key)]),
            el('dd', [txt(e.value)]),
          ]),
      ], classes: 'server-facts'),
      if (checked[node.id] case final time?)
        p([
          txt(
            t('servers.lastCheck', {
              'time': time.toLocal().toIso8601String().substring(11, 19),
            }),
          ),
        ], classes: 'muted small'),
      if (activeNode == node.id)
        p(
          [
            txt(
              t(
                bootstrapId == node.id
                    ? 'servers.installProgress'
                    : 'servers.operationProgress',
              ),
            ),
          ],
          classes: 'notice',
          attributes: {'role': 'status'},
        ),
      if (nodeErrors[node.id] case final code?)
        p(
          [txt(errorMessage(code)), txt(' [$code]', classes: 'muted small')],
          classes: 'notice',
          attributes: {'role': 'alert'},
        ),
      if (!states.containsKey(node.id) && activeNode != node.id)
        p([txt(t('servers.notCheckedHelp'))], classes: 'muted small'),
      if (endpointId == node.id)
        div([
          field(
            'endpoint',
            editedEndpoint,
            (v) => editedEndpoint = v,
            maxLength: 253,
            placeholder: node.host,
            hint: 'servers.endpointHelp',
          ),
          p([txt(t('servers.endpointChangeHelp'))], classes: 'muted small'),
          div([
            action(
              t('common.save'),
              () => unawaited(
                run(() async {
                  await component.api.updateServerEndpoint(
                    node.id,
                    editedEndpoint,
                  );
                  endpointId = null;
                  await load();
                }, nodeId: node.id),
              ),
              disabled: busy,
            ),
            action(
              t('common.cancel'),
              () => setState(() => endpointId = null),
              disabled: busy,
            ),
          ], classes: 'server-actions'),
        ], classes: 'server-edit'),
      if (bootstrapId == node.id) bootstrapForm(node),
      if (removeId == node.id) ...[
        p([txt(t('servers.removeHelp'))]),
        div([
          action(
            t('servers.remove'),
            () => unawaited(run(() => remove(node.id), nodeId: node.id)),
            disabled: busy,
          ),
          action(
            t('common.cancel'),
            () => setState(() => removeId = null),
            disabled: busy,
          ),
        ], classes: 'server-actions'),
      ] else
        div([
          action(
            t('servers.editAddress'),
            () => setState(() {
              endpointId = node.id;
              editedEndpoint = node.endpoint ?? '';
            }),
            disabled: busy,
          ),
          if (bootstrapId != node.id)
            action(
              t('servers.bootstrap'),
              () => setState(() {
                closeBootstrap();
                bootstrapId = node.id;
              }),
              disabled: busy,
            ),
          for (final operation in ServerOperation.values)
            action(
              t('servers.${operation.name}'),
              () => unawaited(
                run(() => operate(node, operation), nodeId: node.id),
              ),
              disabled:
                  busy ||
                  (operation != ServerOperation.status &&
                      operation != ServerOperation.logs &&
                      !states.containsKey(node.id)),
            ),
          action(
            t('servers.remove'),
            () => setState(() => removeId = node.id),
            disabled: busy,
          ),
        ], classes: 'server-actions'),
      el('details', [
        el('summary', [txt(t('servers.manualInstall'))]),
        p([txt(t('servers.enrollmentHelp'))], classes: 'muted small'),
        el('code', [txt(node.publicKey)], classes: 'server-public-key'),
      ], classes: 'server-manual'),
      if (logs[node.id] case final text?)
        el('pre', [
          txt(text.isEmpty ? t('servers.emptyLogs') : text),
        ], classes: 'server-logs'),
    ],
    key: ValueKey(node.id),
    classes: 'settings-panel server-panel',
  );
}
