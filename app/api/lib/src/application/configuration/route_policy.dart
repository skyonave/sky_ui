import 'dart:io';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/api_exception.dart';
import '../core_settings/form.dart';

typedef RouteEdge = ({int from, int to, int index});

class RoutePolicy {
  static const _maxNodes = 8;

  static Map<String, NodeRouting> validate(Connection input) {
    final nodes = input.route.isEmpty ? [Connection.localNode] : input.route;
    if (input.routing.length > nodes.length ||
        input.routing.values.fold(0, (total, p) => total + p.rules.length) >
            NodeRouting.maxTotalRules) {
      _invalid();
    }
    final result = <String, NodeRouting>{};
    for (final entry in input.routing.entries) {
      final index = nodes.indexOf(entry.key);
      if (index < 0) _invalid();
      final policy = entry.value;
      final actions = {
        NodeRouting.next,
        NodeRouting.direct,
        NodeRouting.block,
        for (final node in nodes.skip(index + 1))
          '${NodeRouting.nodePrefix}$node',
      };
      if (!actions.contains(policy.fallback) ||
          policy.rules.length > NodeRouting.maxRules) {
        _invalid();
      }
      final rules = <RoutingRule>[];
      for (final rule in policy.rules) {
        var target = rule.target.trim().toLowerCase();
        final ip = rule.type == 'cidr'
            ? InternetAddress.tryParse(target)
            : null;
        if (ip != null) {
          target =
              '${ip.address}/${ip.type == InternetAddressType.IPv4 ? 32 : 128}';
        }
        final valid = switch (rule.type) {
          'domain' || 'suffix' => CoreSettingsForm.domain(target),
          'cidr' =>
            RegExp(r'^[0-9a-f:.]+/\d{1,3}$').hasMatch(target) &&
                CoreSettingsForm.cidr(target),
          'port' =>
            RegExp(r'^\d{1,5}$').hasMatch(target) &&
                int.parse(target) >= 1 &&
                int.parse(target) <= 65535,
          'network' => target == 'tcp' || target == 'udp',
          _ => false,
        };
        if (!valid || !actions.contains(rule.action)) _invalid();
        rules.add(RoutingRule(rule.type, target, rule.action));
      }
      if (!policy.isDefault) {
        result[entry.key] = NodeRouting(
          fallback: policy.fallback,
          rules: rules,
        );
      }
    }
    return result;
  }

  static Never _invalid() =>
      throw const ApiException('route_policy_invalid', status: 422);

  static Iterable<RouteEdge> edges(Connection connection) sync* {
    final nodes = connection.route;
    for (var from = 0; from < nodes.length - 1; from++) {
      yield (from: from, to: from + 1, index: from);
    }
    // Keep existing sequential link IDs and allocate stable IDs for shortcuts.
    for (var from = 0; from < nodes.length - 2; from++) {
      final policy = connection.routing[nodes[from]];
      if (policy == null) continue;
      final actions = {
        policy.fallback,
        for (final rule in policy.rules) rule.action,
      };
      for (var to = from + 2; to < nodes.length; to++) {
        if (actions.contains('${NodeRouting.nodePrefix}${nodes[to]}')) {
          yield (from: from, to: to, index: _maxNodes + from * _maxNodes + to);
        }
      }
    }
  }
}
