import 'package:sky_ui_shared/sky_ui_shared.dart';

/// Pasting a URL is an explicit conversion to a host-wide rule.
String? websiteHost(String input) {
  final value = input.trim();
  if (value.contains(RegExp(r'\s')) || value.contains('\\')) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !{'http', 'https'}.contains(uri.scheme) ||
      uri.userInfo.isNotEmpty ||
      uri.host.isEmpty)
    return null;
  final String host;
  try {
    host = Uri.decodeComponent(uri.host).toLowerCase();
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  }
  if (host.length > 253 || RegExp(r'^[\d.]+$').hasMatch(host)) return null;
  final label = RegExp(
    r'^[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,61}[\p{L}\p{N}])?$',
    unicode: true,
  );
  return host.split('.').every(label.hasMatch) ? host : null;
}

/// Append missing copies atomically, without changing any node's priorities.
Map<String, NodeRouting>? copyRuleToOtherNodes(
  List<String> nodes,
  Map<String, NodeRouting> policies,
  String source,
  RoutingRule rule, {
  required bool packetIngress,
}) {
  if (rule.type == 'geoip' ||
      rule.target.trim().isEmpty ||
      rule.action.startsWith(NodeRouting.nodePrefix) ||
      rule.target.contains('://'))
    return null;
  final result = {...policies};
  var added = 0;
  for (final node in nodes.where((n) => n != source)) {
    final packet = packetIngress && node == nodes.first;
    if (packet &&
        (!NodeRouting.packetMatches.contains(rule.type) ||
            rule.targets.length != 1 ||
            rule.target.contains(':')))
      return null;
    final policy = policies[node] ?? const NodeRouting();
    if (policy.rules.any(
      (r) =>
          r.type == rule.type &&
          r.target == rule.target &&
          r.action == rule.action,
    ))
      continue;
    if (policy.rules.length >= NodeRouting.maxRules) return null;
    result[node] = NodeRouting(
      fallback: policy.fallback,
      rules: [...policy.rules, rule],
    );
    added++;
  }
  final total = result.values.fold(0, (sum, p) => sum + p.rules.length);
  return added == 0 || total > NodeRouting.maxTotalRules ? null : result;
}
