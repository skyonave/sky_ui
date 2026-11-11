import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../application/access/records.dart';
import 'settings.dart';

class MihomoRouting {
  static const prefix = 'sky-ui/routing/';

  static Iterable<String> get privateBlocks sync* {
    for (final net in MihomoSettings.privateNetworks) {
      yield '${net.contains(':') ? 'IP-CIDR6' : 'IP-CIDR'},$net,REJECT';
    }
  }

  static List<String> rules(
    NodeRouting policy,
    String fallback,
    Iterable<RelayLink> outgoing,
    String connectionId,
  ) {
    String target(String action) => switch (action) {
      NodeRouting.next => fallback,
      NodeRouting.direct => 'DIRECT',
      NodeRouting.block => 'REJECT',
      _ =>
        outgoing
            .firstWhere(
              (link) =>
                  link.connectionId == connectionId &&
                  '${NodeRouting.nodePrefix}${link.targetNode}' == action,
            )
            .name,
    };

    return [
      for (final rule in policy.rules)
        '${_kind(rule)},${rule.target},${target(rule.action)}',
      'MATCH,${target(policy.fallback)}',
    ];
  }

  static String _kind(RoutingRule rule) => switch (rule.type) {
    'domain' => 'DOMAIN',
    'suffix' => 'DOMAIN-SUFFIX',
    'cidr' => rule.target.contains(':') ? 'IP-CIDR6' : 'IP-CIDR',
    'port' => 'DST-PORT',
    'network' => 'NETWORK',
    _ => throw StateError('Invalid routing match type'),
  };

  static void applyIngress(
    Map<String, Object?> listener,
    Map<String, Object?> subRules,
    List<String> rules, {
    required bool cascade,
  }) {
    final accessRule = listener['rule'];
    final existing = subRules[accessRule] as List<String>?;
    final name = existing == null
        ? '$prefix${listener['name']}'
        : accessRule as String;
    subRules[name] = [
      if (cascade)
        ...privateBlocks.where((block) => existing?.contains(block) != true),
      if (existing != null) ...existing.take(existing.length - 1),
      ...rules,
    ];
    listener.remove('proxy');
    listener['rule'] = name;
  }
}
