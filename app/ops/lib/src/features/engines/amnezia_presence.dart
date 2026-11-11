import 'dart:convert';

import '../../platform/host.dart';

const awgActiveSet = 'active_peers';

Set<String> awgActivePeers(Object? value, Map<String, String> tracked) {
  final tables = object(value)['nftables'] as List;
  final set =
      tables.map(object).where((row) => row['set'] != null).single['set']
          as Map;
  final peers = <String>{};
  for (final entry in set['elem'] as List? ?? const []) {
    final element = entry is Map ? entry['elem'] : null;
    if (element is Map && element['expires'] == 0) continue;
    final address = element is Map ? element['val'] : entry;
    if (tracked[address] case final peer?) peers.add(peer);
  }
  return peers;
}

/// The kernel expires active addresses after ten seconds. Only peer hashes
/// leave this worker, never addresses, traffic destinations, or keys.
Future<void> observeAwgTraffic(
  String table,
  Map<String, String> tracked,
) async {
  try {
    final output = await run([
      'nft',
      '-j',
      'list',
      'set',
      'ip',
      table,
      awgActiveSet,
    ], timeout: const Duration(seconds: 1));
    final active = awgActivePeers(jsonDecode(output), tracked);
    final payload = {
      'time': DateTime.now().millisecondsSinceEpoch,
      'active': active.take(120).toList(),
      'complete': active.length <= 120,
    };
    print('sky-ui-peer-traffic ${jsonEncode(payload)}');
  } on Exception {
    // Observation failure is independent of tunnel lifecycle.
  }
}
