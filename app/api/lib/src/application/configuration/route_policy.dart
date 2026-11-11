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
      final coreId = entry.key == input.ingress ? input.coreId : 'mihomo';
      final rules = <RoutingRule>[];
      for (final rule in policy.rules) {
        if (!NodeRouting.matchesFor(coreId).contains(rule.type) ||
            !actions.contains(rule.action) ||
            rule.target.length > NodeRouting.maxTargetLength) {
          _invalid();
        }
        final targets = rule.targets;
        if (targets.isEmpty ||
            targets.length > NodeRouting.maxTargets ||
            (targets.length > 1 &&
                !NodeRouting.allowsTargetList(coreId, rule.type))) {
          _invalid();
        }
        final normalized = targets
            .map((target) => _target(rule.type, target.toLowerCase(), coreId))
            .toSet()
            .join(', ');
        if (normalized.length > NodeRouting.maxTargetLength) _invalid();
        rules.add(RoutingRule(rule.type, normalized, rule.action));
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

  static String _target(String type, String target, String coreId) {
    if ((type == 'geosite' || type == 'geoip') && target.startsWith('$type:')) {
      target = target.substring(type.length + 1);
    }
    if (type == 'domain' || type == 'suffix' || type == 'wildcard') {
      if (target.endsWith('.')) {
        target = target.substring(0, target.length - 1);
      }
    }
    if (type == 'cidr') {
      final ip = InternetAddress.tryParse(target);
      if (ip != null) {
        target =
            '${ip.address}/${ip.type == InternetAddressType.IPv4 ? 32 : 128}';
      }
    }
    final valid = switch (type) {
      'domain' || 'suffix' => CoreSettingsForm.domain(target),
      'wildcard' =>
        target.contains('*') &&
            CoreSettingsForm.domain(target.replaceAll('*', 'x')),
      'keyword' => RegExp(r'^[a-z0-9][a-z0-9.-]{0,62}$').hasMatch(target),
      'geosite' => RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(target),
      'geoip' => target == 'private' || RegExp(r'^[a-z]{2}$').hasMatch(target),
      'cidr' =>
        (coreId != 'amneziawg' || !target.contains(':')) &&
            RegExp(r'^[0-9a-f:.]+/\d{1,3}$').hasMatch(target) &&
            CoreSettingsForm.cidr(target),
      'port' =>
        RegExp(r'^\d{1,5}$').hasMatch(target) &&
            int.parse(target) >= 1 &&
            int.parse(target) <= 65535,
      'network' => target == 'tcp' || target == 'udp',
      _ => false,
    };
    if (!valid) _invalid();
    return target;
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
