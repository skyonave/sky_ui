import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../infrastructure/process/command_runner.dart';
import '../managed_core.dart';
import '../traffic_presence.dart';

class XrayTraffic {
  static const _tag = 'sky-ui/presence';
  final _traffic = TrafficPresence();
  static String _path(ManagedCore core) => '${core.directory}/presence.sock';

  static void configure(Map<String, dynamic> base, ManagedCore core) {
    if (!Platform.isLinux) return;
    final api = base['api'];
    if (api != null && (api is! Map || api['tag'] != _tag)) return;
    base['api'] = {
      'tag': _tag,
      'listen': '${_path(core)},0660',
      'services': ['StatsService'],
    };
    base['stats'] ??= <String, dynamic>{};
    final policy = (base['policy'] ??= <String, dynamic>{}) as Map;
    final levels = (policy['levels'] ??= <String, dynamic>{}) as Map;
    final user = (levels['0'] ??= <String, dynamic>{}) as Map;
    user['statsUserUplink'] = true;
    user['statsUserDownlink'] = true;
    final system = (policy['system'] ??= <String, dynamic>{}) as Map;
    system['statsInboundUplink'] = true;
    system['statsInboundDownlink'] = true;
  }

  Future<Map<String, RecipientPresence>?> sample(
    CommandRunner runner,
    ManagedCore core,
    Map<(String, String?), String> expected,
  ) async {
    if (!Platform.isLinux ||
        ((await FileStat.stat(_path(core))).mode & 0xf000) != 0xc000) {
      return null;
    }
    final result = await runner.run(core.binary, [
      'api',
      'statsquery',
      '--server=unix://${_path(core)}',
      '--timeout=1',
      '--pattern=>>>traffic>>>',
    ], timeout: const Duration(seconds: 2));
    if (result.exitCode != 0) return null;
    final raw = jsonDecode(result.output);
    if (raw is! Map) return null;
    final counters = <String, int>{};
    for (final record in raw['stat'] as List? ?? const []) {
      if (record is! Map || record['name'] is! String) return null;
      final count = int.tryParse(record['value']?.toString() ?? '0');
      if (count == null || count < 0) return null;
      counters[record['name'] as String] = count;
    }
    final samples = <String, TrafficSample>{};
    for (final entry in expected.entries) {
      final (inbound, user) = entry.key;
      final key = user == null ? 'inbound>>>$inbound' : 'user>>>$user';
      samples[key] = (
        grant: entry.value,
        upload: counters['$key>>>traffic>>>uplink'] ?? 0,
        download: counters['$key>>>traffic>>>downlink'] ?? 0,
        start: null,
      );
    }
    _traffic.observe(samples, DateTime.now());
    return {for (final grant in expected.values) grant: _traffic.status(grant)};
  }
}
