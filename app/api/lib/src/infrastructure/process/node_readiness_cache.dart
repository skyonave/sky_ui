import 'dart:async';

import '../../shared/api_exception.dart';

class NodeReadinessCache {
  NodeReadinessCache({
    required this.fetch,
    required this.available,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final Future<List<Map<String, Object?>>> Function(String) fetch;
  final bool Function(String) available;
  final DateTime Function() now;
  final _values = <String, ({DateTime expires, Map<String, String> states})>{};
  final _loading = <String>{};
  final _generations = <String, int>{};

  Map<String, String> read(Iterable<({String node, String engine})> engines) {
    final result = <String, String>{};
    for (final target in engines) {
      final value = _values[target.node];
      final fresh = value != null && value.expires.isAfter(now());
      result['${target.node}/${target.engine}'] = fresh
          ? (value.states[target.engine] ?? 'unknown')
          : 'unknown';
      if (!fresh && !_loading.contains(target.node) && available(target.node)) {
        _loading.add(target.node);
        unawaited(_refresh(target.node, _generations[target.node] ?? 0));
      }
    }
    return result;
  }

  void observe(String node, List<Map<String, Object?>> inventory) {
    _values[node] = (
      expires: now().add(const Duration(seconds: 30)),
      states: {
        for (final entry in inventory)
          if (entry['coreId'] is String)
            entry['coreId'] as String: entry['installed'] != true
                ? 'missing'
                : switch (entry['state']) {
                    'active' => 'ready',
                    'inactive' => 'stopped',
                    'failed' => 'failed',
                    _ => 'unknown',
                  },
      },
    );
  }

  void invalidate(String node) {
    _values.remove(node);
    _generations[node] = (_generations[node] ?? 0) + 1;
  }

  Future<void> _refresh(String node, int generation) async {
    try {
      final value = await fetch(node);
      if ((_generations[node] ?? 0) == generation) observe(node, value);
    } on Object catch (error) {
      if ((_generations[node] ?? 0) == generation) {
        final unknown =
            error is ApiException &&
            {'server_busy', 'server_upgrade_required'}.contains(error.code);
        _values[node] = (
          expires: now().add(const Duration(seconds: 10)),
          states: {
            for (final core in ['mihomo', 'sing-box', 'xray', 'amneziawg'])
              core: unknown ? 'unknown' : 'unreachable',
          },
        );
      }
    } finally {
      _loading.remove(node);
    }
  }
}
