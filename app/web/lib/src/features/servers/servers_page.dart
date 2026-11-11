import 'dart:async';

import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/api/api_client.dart';
import '../../shared/components/page_helpers.dart';
import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';

class ServersPage extends StatefulComponent {
  const ServersPage({required this.api, required this.localName, super.key});

  final ApiClient api;
  final String localName;

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

  Future<void> run(Future<void> Function() operation) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await operation();
    } on ApiClientException catch (failure) {
      error = failure.code;
    } finally {
      if (mounted) setState(() => busy = false);
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
    }
  }

  Future<void> remove(String id) async {
    await component.api.removeServer(id);
    nodes = nodes.where((node) => node.id != id).toList();
    states.remove(id);
    logs.remove(id);
    removeId = null;
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
  }) => label([
    txt(t('servers.$key')),
    input<String>(
      value: value,
      onInput: onInput,
      disabled: busy,
      attributes: {'maxlength': '$maxLength', 'autocomplete': 'off'},
    ),
  ]);

  Component addForm() => div([
    h2([txt(t('servers.add'))]),
    div([
      field('name', name, (value) => name = value, maxLength: 80),
      field('host', host, (value) => host = value, maxLength: 253),
      field('port', port, (value) => port = value, maxLength: 5),
      field('hostKey', hostKey, (value) => hostKey = value, maxLength: 160),
      field('endpoint', endpoint, (value) => endpoint = value, maxLength: 253),
      field(
        'relayAddress',
        relayAddress,
        (value) => relayAddress = value,
        maxLength: 45,
      ),
    ], classes: 'form-grid'),
    p([txt(t('servers.hostKeyHelp'))], classes: 'muted small'),
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
        () => unawaited(run(() => bootstrap(node))),
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
      h2([txt(node.name)]),
      p([
        txt(
          node.host.contains(':')
              ? '[${node.host}]:${node.port}'
              : '${node.host}:${node.port}',
        ),
      ], classes: 'muted small'),
      if (states[node.id] case final state?)
        pill(t('servers.state.$state'), positive: state == 'active'),
      if (!states.containsKey(node.id)) ...[
        p([txt(t('servers.enrollmentHelp'))], classes: 'muted small'),
        el('code', [txt(node.publicKey)], classes: 'server-public-key'),
      ],
      if (bootstrapId == node.id) bootstrapForm(node),
      if (removeId == node.id) ...[
        p([txt(t('servers.removeHelp'))]),
        div([
          action(
            t('servers.remove'),
            () => unawaited(run(() => remove(node.id))),
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
              () => unawaited(run(() => operate(node, operation))),
              disabled:
                  busy ||
                  (operation != ServerOperation.status &&
                      !states.containsKey(node.id)),
            ),
          action(
            t('servers.remove'),
            () => setState(() => removeId = node.id),
            disabled: busy,
          ),
        ], classes: 'server-actions'),
      if (logs[node.id] case final text?)
        el('pre', [
          txt(text.isEmpty ? t('servers.emptyLogs') : text),
        ], classes: 'server-logs'),
    ],
    key: ValueKey(node.id),
    classes: 'settings-panel server-panel',
  );
}
