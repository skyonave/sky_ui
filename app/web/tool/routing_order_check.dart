import 'dart:convert';

import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:sky_ui_web/src/features/routing/rule_order.dart';
import 'package:sky_ui_web/src/features/routing/rule_targets.dart';

void require(bool value, String message) {
  if (!value) throw StateError(message);
}

void main() {
  const exception = RoutingRule(
    'domain',
    'video.example.org',
    NodeRouting.direct,
  );
  const broad = RoutingRule('suffix', 'example.org', NodeRouting.block);
  const network = RoutingRule('network', 'udp', NodeRouting.next);
  const original = [broad, exception, network];
  require(
    websiteHost('https://Example.org:443/news?q=value#top') == 'example.org' &&
        websiteHost('https://user:password@example.org') == null &&
        websiteHost('https://пример.рф/новости') == 'пример.рф' &&
        websiteHost('https://ex%2Fample.org') == null &&
        websiteHost('file:///tmp/file') == null,
    'Extract only website host names.',
  );
  const nodes = ['local', 'transit', 'exit'];
  const policies = {
    'local': NodeRouting(rules: [broad]),
    'transit': NodeRouting(fallback: NodeRouting.direct, rules: [exception]),
  };
  final copied = copyRuleToOtherNodes(
    nodes,
    policies,
    'local',
    broad,
    packetIngress: false,
  )!;
  require(
    copied['transit']!.rules.first == exception &&
        copied['transit']!.rules.last == broad &&
        copied['transit']!.fallback == NodeRouting.direct &&
        copied['exit']!.rules.single == broad &&
        policies.length == 2,
    'Append on every other node without replacing rules or fallback.',
  );
  require(
    copyRuleToOtherNodes(nodes, copied, 'local', broad, packetIngress: false) ==
            null &&
        copyRuleToOtherNodes(nodes, {}, 'exit', broad, packetIngress: true) ==
            null,
    'Avoid duplicates and unsupported packet rules.',
  );

  final prioritized = reorderRoutingRules(original, 1, 0);
  require(
    identical(prioritized.first, exception),
    'Moving an exception up must give it first-match priority.',
  );
  require(
    identical(original.first, broad),
    'Editing must leave the original saved order untouched.',
  );
  require(
    identical(prioritized.last, network),
    'Unrelated priorities must remain stable.',
  );

  final encoded = jsonEncode(
    NodeRouting(fallback: NodeRouting.block, rules: prioritized).toJson(),
  );
  final restored = NodeRouting.fromJson(
    jsonDecode(encoded) as Map<String, dynamic>,
  );
  require(
    restored.rules.map((rule) => rule.target).join('|') ==
        'video.example.org|example.org|udp',
    'Saving and loading must preserve displayed priority.',
  );
  require(
    restored.fallback == NodeRouting.block,
    'Reordering must not change the unmatched-traffic action.',
  );

  final last = reorderRoutingRules(prioritized, 0, 2);
  require(
    identical(last.last, exception),
    'Dragging downward must use the indicated final position.',
  );
  final first = reorderRoutingRules(last, 2, 0);
  require(
    first.map((rule) => rule.target).join('|') ==
        prioritized.map((rule) => rule.target).join('|'),
    'Dragging back must restore the exact order.',
  );
  require(
    reorderRoutingRules(original, 1, 1).length == original.length,
    'Dropping on the same row must preserve the rule count.',
  );

  for (final indexes in [(-1, 0), (0, 3), (3, 0)]) {
    var rejected = false;
    try {
      reorderRoutingRules(original, indexes.$1, indexes.$2);
    } on RangeError {
      rejected = true;
    }
    require(rejected, 'Stale drag positions must not silently remove a rule.');
  }
  print('Routing priority checks passed.');
}
