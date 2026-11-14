import 'package:sky_ui_shared/sky_ui_shared.dart';

/// Moves a rule to its final priority while preserving the other priorities.
List<RoutingRule> reorderRoutingRules(
  List<RoutingRule> rules,
  int from,
  int to,
) {
  RangeError.checkValidIndex(from, rules, 'from');
  RangeError.checkValidIndex(to, rules, 'to');
  final reordered = [...rules];
  reordered.insert(to, reordered.removeAt(from));
  return reordered;
}
