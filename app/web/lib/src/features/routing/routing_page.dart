import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';
import 'route_rules.dart';

class RoutingPage extends StatefulComponent {
  const RoutingPage({
    required this.snapshot,
    required this.editable,
    required this.save,
    required this.remove,
    super.key,
  });
  final PanelSnapshot snapshot;
  final bool editable;
  final Future<bool> Function(int, NamedRoute) save;
  final Future<bool> Function(int, String) remove;
  @override
  State<RoutingPage> createState() => _RoutingPageState();
}

class _RoutingPageState extends State<RoutingPage> {
  static const t = AppStrings();
  String? editing, removing;
  String name = '', selectedNode = Connection.localNode;
  List<String> nodes = [];
  Map<String, NodeRouting> policies = {};
  int revision = 0;
  bool saving = false;
  bool resetConfirm = false;
  String? error;
  Map<String, String> get names => {
    Connection.localNode: component.snapshot.serverName,
    ...component.snapshot.routeNodes,
  };
  List<Connection> bound(String id) =>
      component.snapshot.connections.where((c) => c.routeId == id).toList();
  void edit(NamedRoute? route) => setState(() {
    editing = route?.id ?? '';
    removing = null;
    name = route?.name ?? '';
    nodes = [...?route?.nodes];
    if (nodes.isEmpty) nodes = [Connection.localNode];
    selectedNode = nodes.first;
    policies = {...?route?.policies};
    revision = component.snapshot.revision;
    error = null;
    resetConfirm = false;
  });
  void close() => setState(() {
    editing = null;
    error = null;
  });
  String role(int index, int length) => t(
    length == 1
        ? 'routes.both'
        : index == 0
        ? 'builder.routeIngress'
        : index == length - 1
        ? 'builder.routeEgress'
        : 'builder.routeTransit',
  );
  bool get editable => component.editable && !saving;
  bool get invalidPolicies => policies.entries.any((e) {
    final index = nodes.indexOf(e.key);
    bool invalid(String action) =>
        action.startsWith(NodeRouting.nodePrefix) &&
        !nodes
            .skip(index + 1)
            .contains(action.substring(NodeRouting.nodePrefix.length));
    return index < 0 ||
        invalid(e.value.fallback) ||
        e.value.rules.any((r) => invalid(r.action));
  });
  void move(int from, int to) => setState(() {
    nodes.insert(to, nodes.removeAt(from));
  });

  @override
  Component build(BuildContext context) => div([
    div([
      h1([txt(t('nav.routing'))]),
      if (editing == null)
        action(
          t('routes.add'),
          () => edit(null),
          glyph: 'plus',
          classes: 'button primary',
          disabled: !editable,
        ),
    ], classes: 'page-heading'),
    if (editing != null)
      editor()
    else ...[
      if (component.snapshot.routes.isEmpty)
        p([txt(t('routes.empty'))], classes: 'notice'),
      for (final route in component.snapshot.routes) card(route),
    ],
  ], classes: 'routing-page');

  Component card(NamedRoute route) {
    final connections = bound(route.id);
    return div([
      div([
        h2([txt(route.name)]),
        txt(
          t(connections.isEmpty ? 'routes.unused' : 'routes.assigned', {
            'count': connections.length,
          }),
          classes: 'availability-chip',
        ),
        action(
          t('common.edit'),
          () => edit(route),
          glyph: 'edit',
          disabled: !editable,
        ),
      ], classes: 'server-heading'),
      el('ol', [
        for (var i = 0; i < route.nodes.length; i++)
          el('li', [
            txt(names[route.nodes[i]] ?? route.nodes[i]),
            span([txt(role(i, route.nodes.length))], classes: 'muted small'),
          ]),
      ], classes: 'route-chain'),
      p([
        txt(
          t(
            route.nodes.contains(Connection.localNode)
                ? 'routes.panelParticipates'
                : 'routes.remoteOnly',
          ),
        ),
      ], classes: 'muted small'),
      p([
        txt(
          t('routes.ruleCount', {
            'count': route.policies.values.fold<int>(
              0,
              (n, p) => n + p.rules.length,
            ),
          }),
        ),
      ], classes: 'muted small'),
      if (connections.isNotEmpty)
        el('details', [
          el('summary', [txt(t('routes.connections'))]),
          connectionTable(connections),
        ]),
      if (removing == route.id)
        div([
          p([txt(t('routes.removeConfirm'))]),
          div([
            action(
              t('common.cancel'),
              () => setState(() => removing = null),
              disabled: !editable,
            ),
            action(t('servers.remove'), () async {
              setState(() => saving = true);
              try {
                final ok = await component.remove(
                  component.snapshot.revision,
                  route.id,
                );
                if (mounted && ok) setState(() => removing = null);
              } finally {
                if (mounted) setState(() => saving = false);
              }
            }, disabled: !editable),
          ], classes: 'server-actions'),
        ])
      else
        div([
          action(
            t('servers.remove'),
            () => setState(() => removing = route.id),
            disabled: !editable || connections.isNotEmpty,
            glyph: 'trash',
          ),
          if (connections.isNotEmpty)
            txt(t('routes.detachBeforeDelete'), classes: 'muted small'),
        ], classes: 'server-actions'),
    ], classes: 'route-card');
  }

  Component connectionTable(List<Connection> connections) => el('div', [
    el('table', [
      el('thead', [
        el('tr', [
          for (final key in [
            'routing.connection',
            'routes.entryAddress',
            'routes.ports',
          ])
            el('th', [txt(t(key))]),
        ]),
      ]),
      el('tbody', [
        for (final c in connections)
          el('tr', [
            el('td', [
              txt(c.name),
              span([txt(c.coreId)], classes: 'muted small'),
            ]),
            el('td', [txt('${names[c.ingress] ?? c.ingress}:${c.port ?? ''}')]),
            el('td', [
              txt(
                c.routePorts.isEmpty
                    ? t('routes.noRelay')
                    : c.routePorts.join(', '),
              ),
              for (final link in c.routeShortcuts)
                span([
                  txt(
                    '${names[link.from] ?? link.from} / ${names[link.to] ?? link.to}: ${link.port}',
                  ),
                ], classes: 'muted small'),
            ]),
          ]),
      ]),
    ], classes: 'data-table'),
  ], classes: 'table-scroll');

  Component editor() {
    final bindings = bound(editing!);
    final node = nodes.contains(selectedNode) ? selectedNode : nodes.first;
    final isAwg =
        node == nodes.first && bindings.any((c) => c.coreId == 'amneziawg');
    final otherRules = policies.entries
        .where((e) => e.key != node)
        .fold<int>(0, (n, e) => n + e.value.rules.length);
    return div([
      div([
        h2([txt(t(editing!.isEmpty ? 'routes.add' : 'routes.edit'))]),
        txt(
          t('routes.assigned', {'count': bindings.length}),
          classes: 'availability-chip',
        ),
      ], classes: 'server-heading'),
      label([
        txt(t('routes.name')),
        input<String>(
          value: name,
          disabled: !editable,
          onInput: (v) => name = v,
          attributes: {
            'maxlength': '80',
            'placeholder': t('routes.nameExample'),
          },
        ),
      ]),
      h3([txt(t('routes.path'))], classes: 'form-section-title'),
      p([txt(t('routes.pathHelp'))], classes: 'muted small'),
      for (var i = 0; i < nodes.length; i++)
        div([
          txt('${i + 1}', classes: 'route-order'),
          label([
            txt(role(i, nodes.length)),
            select(
              [
                for (final e in {
                  ...names,
                  for (final n in nodes) n: names[n] ?? n,
                }.entries)
                  if (e.key == nodes[i] || !nodes.contains(e.key))
                    option([txt(e.value)], value: e.key),
              ],
              value: nodes[i],
              disabled: !editable,
              onChange: (values) {
                if (values.isNotEmpty)
                  setState(() {
                    nodes[i] = values.single;
                  });
              },
            ),
          ]),
          iconButton(
            'up',
            t('routes.moveUp'),
            () => move(i, i - 1),
            disabled: !editable || i == 0,
          ),
          iconButton(
            'down',
            t('routes.moveDown'),
            () => move(i, i + 1),
            disabled: !editable || i == nodes.length - 1,
          ),
          iconButton(
            'trash',
            t('builder.routeRemove'),
            () => setState(() => nodes.removeAt(i)),
            disabled: !editable || nodes.length == 1,
          ),
        ], classes: 'route-field'),
      action(
        t('builder.routeAdd'),
        () => setState(() {
          nodes.add(names.keys.firstWhere((n) => !nodes.contains(n)));
        }),
        glyph: 'plus',
        disabled:
            !editable || nodes.length >= 8 || names.keys.every(nodes.contains),
      ),
      p([
        txt(
          t(
            nodes.contains(Connection.localNode)
                ? 'routes.panelParticipates'
                : 'routes.remoteOnly',
          ),
        ),
      ], classes: 'notice'),
      if (nodes.first != Connection.localNode)
        p([txt(t('routes.remoteCapabilities'))], classes: 'muted small'),
      if (invalidPolicies)
        div([
          p([txt(t('routes.policyConflict'))], classes: 'field-error'),
          if (resetConfirm) ...[
            p([txt(t('routes.resetConfirm'))]),
            div([
              action(
                t('common.cancel'),
                () => setState(() => resetConfirm = false),
                disabled: !editable,
              ),
              action(
                t('routes.resetPolicies'),
                () => setState(() {
                  policies.clear();
                  resetConfirm = false;
                }),
                disabled: !editable,
              ),
            ], classes: 'server-actions'),
          ] else
            action(
              t('routes.resetPolicies'),
              () => setState(() => resetConfirm = true),
              disabled: !editable,
            ),
        ]),
      h3([txt(t('routes.nodeRules'))], classes: 'form-section-title'),
      div([
        for (final n in nodes)
          button(
            [txt(names[n] ?? n)],
            type: ButtonType.button,
            classes: 'tab ${node == n ? 'active' : ''}',
            attributes: {'aria-pressed': '${node == n}'},
            disabled: !editable,
            onClick: () => setState(() => selectedNode = n),
          ),
      ], classes: 'tabs routing-tabs'),
      RouteRules(
        nodes: nodes,
        node: node,
        names: names,
        coreId: isAwg ? 'amneziawg' : 'mihomo',
        policy: policies[node] ?? const NodeRouting(),
        ruleLimit: (NodeRouting.maxTotalRules - otherRules).clamp(
          0,
          NodeRouting.maxRules,
        ),
        editable: editable,
        onChange: (p) => setState(() {
          if (p.isDefault) {
            policies.remove(node);
          } else {
            policies[node] = p;
          }
        }),
      ),
      if (bindings.isNotEmpty) ...[
        p([
          txt(t('routes.applyAll', {'count': bindings.length})),
        ], classes: 'notice'),
        connectionTable(bindings),
      ],
      if (error != null)
        p(
          [txt(t(error!))],
          classes: 'field-error',
          attributes: {'role': 'alert'},
        ),
      div([
        action(t('common.cancel'), close, disabled: !editable),
        action(
          t(saving ? 'routes.saving' : 'common.save'),
          () async {
            if (name.trim().isEmpty) {
              setState(() => error = 'common.invalidName');
              return;
            }
            setState(() {
              saving = true;
              error = null;
            });
            try {
              final ok = await component.save(
                revision,
                NamedRoute(
                  id: editing!,
                  name: name.trim(),
                  nodes: [...nodes],
                  policies: {...policies},
                ),
              );
              if (mounted) {
                if (ok) {
                  close();
                } else {
                  setState(() => error = 'routes.saveFailed');
                }
              }
            } finally {
              if (mounted) setState(() => saving = false);
            }
          },
          classes: 'button primary',
          disabled: !editable || invalidPolicies,
        ),
      ], classes: 'routing-actions'),
    ], classes: 'routing-editor');
  }
}
