import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';
import '../../shared/protocols/catalog.dart';
import 'route_rules.dart';

class RoutingPage extends StatefulComponent {
  const RoutingPage({
    required this.snapshot,
    required this.editable,
    required this.save,
    super.key,
  });

  final PanelSnapshot snapshot;
  final bool editable;
  final Future<bool> Function(int, String, String, NodeRouting) save;

  @override
  State<RoutingPage> createState() => _RoutingPageState();
}

class _RoutingPageState extends State<RoutingPage> {
  static const t = AppStrings();
  String selectedNode = Connection.localNode;
  String? selectedConnection;
  NodeRouting? draft;
  int? draftRevision;

  @override
  Component build(BuildContext context) {
    final snapshot = component.snapshot;
    final names = {
      ...snapshot.routeNodes,
      Connection.localNode: t('routing.local'),
    };
    final node = names.containsKey(selectedNode)
        ? selectedNode
        : Connection.localNode;
    final connections = snapshot.connections
        .where((c) => c.ingress == node || c.route.contains(node))
        .toList();
    final connection =
        connections.where((c) => c.id == selectedConnection).firstOrNull ??
        (draft == null ? connections.firstOrNull : null);

    return div([
      div([
        h1([txt(t('nav.routing'))]),
      ], classes: 'page-heading'),
      div([
        for (final id in [
          Connection.localNode,
          ...names.keys.where((id) => id != Connection.localNode),
        ])
          button(
            [txt(names[id]!)],
            type: ButtonType.button,
            classes: 'tab ${id == node ? 'active' : ''}',
            attributes: {'aria-pressed': '${id == node}'},
            disabled: draft != null,
            onClick: () => setState(() {
              selectedNode = id;
              selectedConnection = null;
            }),
          ),
      ], classes: 'tabs routing-tabs'),
      if (connection == null && draft != null)
        action(t('common.cancel'), _reset)
      else if (connection == null)
        p([txt(t('routing.noConnections'))], classes: 'muted')
      else
        _editor(connection, connections, names, node),
    ], classes: 'routing-page');
  }

  Component _editor(
    Connection connection,
    List<Connection> connections,
    Map<String, String> names,
    String node,
  ) {
    final nodes = connection.route.isEmpty
        ? [Connection.localNode]
        : connection.route;
    final index = nodes.indexOf(node);
    final policy = draft ?? connection.routing[node] ?? const NodeRouting();
    final otherRules = connection.routing.entries
        .where((entry) => entry.key != node)
        .fold<int>(0, (count, entry) => count + entry.value.rules.length);
    final limit = (NodeRouting.maxTotalRules - otherRules).clamp(
      0,
      NodeRouting.maxRules,
    );
    return div([
      div([
        label([
          txt(t('routing.connection')),
          select(
            [
              for (final item in connections)
                option([
                  txt('${item.name} · ${coreName(item.coreId)}'),
                ], value: item.id),
            ],
            value: connection.id,
            disabled: draft != null,
            onChange: (values) {
              if (values.isNotEmpty)
                setState(() => selectedConnection = values.single);
            },
          ),
        ]),
        if (nodes.length > 1)
          txt(
            t(
              index == 0
                  ? 'builder.routeIngress'
                  : index == nodes.length - 1
                  ? 'builder.routeEgress'
                  : 'builder.routeTransit',
            ),
            classes: 'protocol-tag',
          ),
      ], classes: 'routing-connection'),
      RouteRules(
        nodes: nodes,
        node: node,
        names: names,
        coreId: node == connection.ingress ? connection.coreId : 'mihomo',
        policy: policy,
        ruleLimit: limit,
        editable: component.editable,
        onChange: (value) => setState(() {
          draftRevision ??= component.snapshot.revision;
          selectedConnection = connection.id;
          draft = value;
        }),
      ),
      div([
        action(
          t('common.cancel'),
          _reset,
          disabled: draft == null || !component.editable,
        ),
        action(
          t('common.save'),
          () async {
            final value = draft;
            if (value == null) return;
            final saved = await component.save(
              draftRevision!,
              connection.id,
              node,
              value,
            );
            if (mounted && saved) _reset();
          },
          classes: 'button primary',
          disabled: draft == null || !component.editable,
        ),
      ], classes: 'routing-actions'),
      if (connection.routeShortcuts.any(
        (link) => link.from == node || link.to == node,
      ))
        div([
          h3([txt(t('routing.links'))], classes: 'form-section-title'),
          for (final link in connection.routeShortcuts)
            if (link.from == node || link.to == node)
              p([
                txt(
                  t('routing.link', {
                    'from': names[link.from] ?? link.from,
                    'to': names[link.to] ?? link.to,
                    'port': link.port,
                  }),
                ),
              ], classes: 'muted small'),
        ], classes: 'route-rules'),
    ], classes: 'routing-editor');
  }

  void _reset() => setState(() {
    draft = null;
    draftRevision = null;
  });
}
