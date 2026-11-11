import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';

class RouteRules extends StatelessComponent {
  const RouteRules({
    required this.nodes,
    required this.names,
    required this.policies,
    required this.editable,
    required this.onChange,
    super.key,
  });

  final List<String> nodes;
  final Map<String, String> names;
  final Map<String, NodeRouting> policies;
  final bool editable;
  final void Function(String, NodeRouting) onChange;
  static const _types = ['domain', 'suffix', 'cidr', 'port', 'network'];
  static const _examples = {
    'domain': 'www.example.com',
    'suffix': 'example.com',
    'cidr': '203.0.113.0/24',
    'port': '443',
  };
  static const t = AppStrings();

  @override
  Component build(BuildContext context) => div([
    h3([txt(t('routing.title'))], classes: 'form-section-title'),
    p([txt(t('routing.help'))], classes: 'muted small'),
    for (var index = 0; index < nodes.length; index++) _node(index),
  ], classes: 'route-rules');

  Component _node(int index) {
    final id = nodes[index];
    final policy = policies[id] ?? const NodeRouting();
    final rows = policy.rules;
    final next = index + 1 < nodes.length ? nodes[index + 1] : null;
    final routeAction = {
      NodeRouting.next: next == null
          ? t('routing.direct')
          : t('routing.next', {'node': names[next] ?? next}),
    };
    final actions = {
      NodeRouting.direct: t('routing.direct'),
      NodeRouting.block: t('routing.block'),
      for (final node in nodes.skip(index + 1))
        '${NodeRouting.nodePrefix}$node': t('routing.forward', {
          'node': names[node] ?? node,
        }),
    };
    void update(List<RoutingRule> rules) =>
        onChange(id, NodeRouting(fallback: policy.fallback, rules: rules));
    void move(int from, int to) {
      final next = [...rows];
      next.insert(to, next.removeAt(from));
      update(next);
    }

    return el(
      'details',
      [
        el('summary', [
          txt(
            names[id] ?? (id == Connection.localNode ? t('routing.local') : id),
          ),
          txt(
            t(
              index == 0
                  ? 'builder.routeIngress'
                  : next == null
                  ? 'builder.routeEgress'
                  : 'builder.routeTransit',
            ),
            classes: 'muted',
          ),
          if (!policy.isDefault) txt('${rows.length}', classes: 'protocol-tag'),
        ]),
        div([
          for (var i = 0; i < rows.length; i++)
            _row(
              rows[i],
              {
                if (rows[i].action == NodeRouting.next) ...routeAction,
                ...actions,
              },
              change: (value) => update([...rows]..[i] = value),
              remove: () => update([...rows]..removeAt(i)),
              up: i > 0 ? () => move(i, i - 1) : null,
              down: i + 1 < rows.length ? () => move(i, i + 1) : null,
            ),
          action(
            t('routing.add'),
            () => update([
              ...rows,
              const RoutingRule('suffix', '', NodeRouting.block),
            ]),
            glyph: 'plus',
            disabled:
                !editable ||
                rows.length >= NodeRouting.maxRules ||
                policies.values.fold(0, (total, p) => total + p.rules.length) >=
                    NodeRouting.maxTotalRules,
          ),
          _select(
            'routing.fallback',
            next == null && policy.fallback == NodeRouting.direct
                ? NodeRouting.next
                : policy.fallback,
            {
              ...routeAction,
              for (final entry in actions.entries)
                if (next != null || entry.key != NodeRouting.direct)
                  entry.key: entry.value,
            },
            (value) => onChange(id, NodeRouting(fallback: value, rules: rows)),
          ),
        ], classes: 'route-rule-body'),
      ],
      classes: 'route-rule-node',
      key: ValueKey(id),
    );
  }

  Component _row(
    RoutingRule rule,
    Map<String, String> actions, {
    required void Function(RoutingRule) change,
    required void Function() remove,
    required void Function()? up,
    required void Function()? down,
  }) => div([
    _select(
      'routing.type',
      rule.type,
      {for (final type in _types) type: t('routing.$type')},
      (type) => change(
        RoutingRule(type, type == 'network' ? 'tcp' : '', rule.action),
      ),
    ),
    if (rule.type == 'network')
      _select('routing.target', rule.target, const {
        'tcp': 'TCP',
        'udp': 'UDP',
      }, (value) => change(RoutingRule(rule.type, value, rule.action)))
    else
      label([
        txt(t('routing.target')),
        input<String>(
          type: InputType.text,
          value: rule.target,
          disabled: !editable,
          attributes: {
            'placeholder': _examples[rule.type] ?? '',
            'maxlength': '253',
          },
          onInput: (value) =>
              change(RoutingRule(rule.type, value, rule.action)),
        ),
      ]),
    _select(
      'routing.action',
      rule.action,
      actions,
      (value) => change(RoutingRule(rule.type, rule.target, value)),
    ),
    div([
      iconButton(
        'up',
        t('routing.up'),
        up ?? () {},
        disabled: !editable || up == null,
      ),
      iconButton(
        'down',
        t('routing.down'),
        down ?? () {},
        disabled: !editable || down == null,
      ),
      iconButton('trash', t('routing.remove'), remove, disabled: !editable),
    ], classes: 'route-rule-actions'),
  ], classes: 'route-rule-row');

  Component _select(
    String labelKey,
    String value,
    Map<String, String> options,
    void Function(String) change,
  ) => label([
    txt(t(labelKey)),
    select(
      [
        if (!options.containsKey(value))
          option([txt(t('routing.missingNode'))], value: value, disabled: true),
        for (final entry in options.entries)
          option([txt(entry.value)], value: entry.key),
      ],
      value: value,
      disabled: !editable,
      onChange: (values) {
        if (values.isNotEmpty) change(values.single);
      },
    ),
  ]);
}
