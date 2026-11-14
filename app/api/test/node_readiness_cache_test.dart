import 'dart:async';

import 'package:sky_ui_api/src/infrastructure/process/node_readiness_cache.dart';
import 'package:sky_ui_api/src/shared/api_exception.dart';
import 'package:test/test.dart';

void main() {
  const targets = [
    (node: 'node', engine: 'xray'),
    (node: 'node', engine: 'amneziawg'),
  ];
  test(
    'snapshot never waits for SSH and expires successful observations',
    () async {
      var now = DateTime.utc(2026);
      var calls = 0;
      final reply = Completer<List<Map<String, Object?>>>();
      final cache = NodeReadinessCache(
        fetch: (_) {
          calls++;
          return reply.future;
        },
        available: (_) => true,
        now: () => now,
      );
      expect(cache.read(targets), {
        'node/xray': 'unknown',
        'node/amneziawg': 'unknown',
      });
      cache.read(targets);
      expect(calls, 1);
      reply.complete([
        {'coreId': 'xray', 'installed': true, 'state': 'active'},
        {'coreId': 'amneziawg', 'installed': false, 'state': 'inactive'},
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(cache.read(targets), {
        'node/xray': 'ready',
        'node/amneziawg': 'missing',
      });
      now = now.add(const Duration(seconds: 31));
      expect(cache.read(targets)['node/xray'], 'unknown');
      expect(calls, 2);
    },
  );
  test(
    'mutation invalidates observations and stale in-flight result cannot restore ready',
    () async {
      final reply = Completer<List<Map<String, Object?>>>();
      var available = true;
      final cache = NodeReadinessCache(
        fetch: (_) => reply.future,
        available: (_) => available,
      );
      cache.read(targets);
      cache.invalidate('node');
      available = false;
      reply.complete([
        {'coreId': 'xray', 'installed': true, 'state': 'active'},
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(cache.read(targets)['node/xray'], 'unknown');
      cache.observe('node', [
        {'coreId': 'xray', 'installed': true, 'state': 'inactive'},
      ]);
      expect(cache.read(targets)['node/xray'], 'stopped');
    },
  );
  test('unreachable observations retry after short cache interval', () async {
    var now = DateTime.utc(2026), calls = 0;
    final cache = NodeReadinessCache(
      fetch: (_) async {
        calls++;
        throw const ApiException('server_ssh_failed');
      },
      available: (_) => true,
      now: () => now,
    );
    cache.read(targets);
    await Future<void>.delayed(Duration.zero);
    expect(cache.read(targets)['node/xray'], 'unreachable');
    expect(calls, 1);
    now = now.add(const Duration(seconds: 11));
    cache.read(targets);
    expect(calls, 2);
  });
}
