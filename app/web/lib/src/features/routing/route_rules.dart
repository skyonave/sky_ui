import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:web/web.dart' as web;

import '../../shared/components/field_help.dart';
import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';
import 'rule_order.dart';

class RouteRules extends StatefulComponent {
  const RouteRules({
    required this.nodes,
    required this.node,
    required this.names,
    required this.policy,
    required this.coreId,
    required this.ruleLimit,
    required this.editable,
    required this.onChange,
    super.key,
  });

  final List<String> nodes;
  final String node, coreId;
  final Map<String, String> names;
  final NodeRouting policy;
  final int ruleLimit;
  final bool editable;
  final void Function(NodeRouting) onChange;
  @override
  State<RouteRules> createState() => _RouteRulesState();
}

class _RouteRulesState extends State<RouteRules> {
  int? dragging, dropTarget;
  String get coreId => component.coreId;
  bool get editable => component.editable;
  static const _examples = {
    'domain': 'www.example.com',
    'suffix': 'example.com',
    'wildcard': '*.example.com',
    'keyword': 'example',
    'geosite': 'youtube, category-ads-all',
    'cidr': '203.0.113.0/24',
    'geoip': 'ru, private',
    'port': '443',
  };
  static const t = AppStrings();

  @override
  Component build(BuildContext context) {
    final nodes = component.nodes;
    final node = component.node;
    final names = component.names;
    final policy = component.policy;
    final onChange = component.onChange;
    final index = nodes.indexOf(node);
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
        onChange(NodeRouting(fallback: policy.fallback, rules: rules));
    void move(int from, int to) {
      update(reorderRoutingRules(rows, from, to));
    }

    return div([
      div([
        txt(t('routing.orderHelp'), classes: 'muted small'),
        FieldHelp(
          id: 'route-rules-$node-help',
          label: t('routing.title'),
          description: t(
            coreId == 'amneziawg' ? 'routing.packetHelp' : 'routing.help',
          ),
          buttonLabel: t('common.help', {'name': t('routing.title')}),
        ),
      ], classes: 'route-rule-help'),
      if (rows.isEmpty)
        p([txt(t('routing.empty'))], classes: 'route-rules-empty muted'),
      el('ol', [
        for (var i = 0; i < rows.length; i++)
          _row(
            rows[i],
            {
              if (rows[i].action == NodeRouting.next) ...routeAction,
              ...actions,
            },
            i,
            change: (value) => update([...rows]..[i] = value),
            remove: () => update([...rows]..removeAt(i)),
            up: i > 0 ? () => move(i, i - 1) : null,
            down: i + 1 < rows.length ? () => move(i, i + 1) : null,
            drop: () {
              final from = dragging;
              setState(() {
                dragging = null;
                dropTarget = null;
              });
              if (editable && from != null && from != i && from < rows.length)
                move(from, i);
            },
          ),
      ], classes: 'route-rules-list'),
      action(
        t('routing.add'),
        () => update([
          ...rows,
          RoutingRule(
            NodeRouting.matchesFor(coreId).first,
            '',
            NodeRouting.block,
          ),
        ]),
        glyph: 'plus',
        disabled: !editable || rows.length >= component.ruleLimit,
      ),
      div([
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
          (value) => onChange(NodeRouting(fallback: value, rules: rows)),
        ),
        txt(t('routing.fallbackHelp'), classes: 'muted small'),
      ], classes: 'route-rule-fallback'),
    ], classes: 'route-rule-body');
  }

  Component _row(
    RoutingRule rule,
    Map<String, String> actions,
    int index, {
    required void Function(RoutingRule) change,
    required void Function() remove,
    required void Function()? up,
    required void Function()? down,
    required void Function() drop,
  }) => el(
    'li',
    [
      div([
        txt('${index + 1}', classes: 'route-rule-number'),
        el(
          'button',
          [icon('menu')],
          classes: 'icon-button route-rule-grip',
          attributes: {
            'type': 'button',
            'draggable': '$editable',
            'tabindex': '-1',
            'aria-label': t('routing.drag'),
            'title': t('routing.drag'),
            if (!editable) 'disabled': '',
          },
          events: {
            'dragstart': (event) {
              if (!editable) return;
              final data = (event as web.DragEvent).dataTransfer;
              data?.setData('text/plain', '$index');
              if (data != null) data.effectAllowed = 'move';
              setState(() {
                dragging = index;
                dropTarget = null;
              });
            },
            'dragend': (_) => setState(() {
              dragging = null;
              dropTarget = null;
            }),
          },
        ),
      ], classes: 'route-rule-priority'),
      _select(
        'routing.type',
        rule.type,
        {
          for (final type in NodeRouting.matchesFor(coreId))
            type: t('routing.$type'),
        },
        (type) => change(
          RoutingRule(type, type == 'network' ? 'tcp' : '', rule.action),
        ),
        classes: 'route-rule-match',
      ),
      if (rule.type == 'network')
        _select(
          'routing.target',
          rule.target,
          const {'tcp': 'TCP', 'udp': 'UDP'},
          (value) => change(RoutingRule(rule.type, value, rule.action)),
          classes: 'route-rule-target',
        )
      else
        _target(rule, index, change),
      _select(
        'routing.action',
        rule.action,
        actions,
        (value) => change(RoutingRule(rule.type, rule.target, value)),
        classes: 'route-rule-action',
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
    ],
    classes:
        'route-rule-row ${dragging == index ? 'is-dragging' : ''} ${dropTarget == index && dragging != index ? (dragging! < index ? 'drop-after' : 'drop-before') : ''}',
    attributes: {'data-rule-order': '$index'},
    events: {
      'dragover': (event) {
        if (!editable || dragging == null) return;
        (event as web.DragEvent).preventDefault();
        if (dropTarget != index) setState(() => dropTarget = index);
      },
      'drop': (event) {
        if (dragging == null) return;
        (event as web.DragEvent).preventDefault();
        drop();
      },
    },
  );

  Component _target(
    RoutingRule rule,
    int index,
    void Function(RoutingRule) change,
  ) {
    final id = 'routing-${component.node}-target-$index';
    final label = t('routing.target');
    final multiple = NodeRouting.allowsTargetList(coreId, rule.type);
    final help = [
      t('routing.help.${rule.type}'),
      if (multiple) t('routing.help.list', {'count': NodeRouting.maxTargets}),
    ].join(' ');
    final attributes = {
      'placeholder': _examples[rule.type] ?? '',
      'maxlength': multiple ? '${NodeRouting.maxTargetLength}' : '253',
    };
    void update(String value) =>
        change(RoutingRule(rule.type, value, rule.action));

    return div([
      div([
        el('label', [txt(label)], attributes: {'for': id}),
        FieldHelp(
          id: '$id-help',
          label: t('routing.${rule.type}'),
          description: help,
          buttonLabel: t('common.help', {'name': label}),
        ),
      ], classes: 'field-label'),
      input<String>(
        id: id,
        type: InputType.text,
        value: rule.target,
        disabled: !editable,
        attributes: attributes,
        onInput: update,
      ),
    ], classes: 'route-rule-target');
  }

  Component _select(
    String labelKey,
    String value,
    Map<String, String> options,
    void Function(String) change, {
    String? classes,
  }) => label([
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
  ], classes: classes);
}
