import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../application/access/records.dart';
import '../../infrastructure/process/command_runner.dart';
import '../../shared/api_exception.dart';
import '../contracts.dart';
import '../managed_core.dart';
import '../proxy/adapter.dart';
import 'configuration.dart';

class AmneziaAdapter extends JsonProxyAdapter {
  AmneziaAdapter(CommandRunner runner, ProcessSupervisor supervisor)
    : super('amneziawg', runner, supervisor);
  @override
  String get name => 'AmneziaWG';

  @override
  Future<Map<String, RecipientPresence>> presence(
    ManagedCore core,
    PanelData data,
  ) async {
    final expected = <String, String>{};
    for (final stored in data.listeningConnections) {
      final c = stored.value;
      final name = AmneziaConfiguration.interfaceName(c.id);
      for (final grant in data.activeGrants(c.id)) {
        final key = grant.credentials['publicKey'];
        if (key == null) continue;
        final hex = base64
            .decode(key)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        expected[digest('$name/$hex')] = grant.id;
      }
    }
    if (expected.isEmpty) return {};
    const prefix = 'sky-ui-peer-traffic ';
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final line in await recentPresenceLogs(core, 5)) {
      if (!line.startsWith(prefix)) continue;
      final payload = jsonDecode(line.substring(prefix.length));
      if (payload is! Map ||
          payload['time'] is! int ||
          payload['active'] is! List)
        continue;
      final elapsed = now - (payload['time'] as int);
      if (elapsed < -1000 || elapsed > 5000) continue;
      final active = (payload['active'] as List).toSet();
      return {
        for (final entry in expected.entries)
          if (active.contains(entry.key))
            entry.value: RecipientPresence.online
          else if (payload['complete'] == true)
            entry.value: RecipientPresence.offline,
      };
    }
    return {};
  }

  @override
  Future<BinaryProbe> probe(ManagedCore core) async {
    if (!await File(core.binary).exists())
      return const BinaryProbe(false, null);
    final result = await runner.run(core.binary, ['--version']);
    final version = RegExp(r'\b3\.1\.\d+').firstMatch(result.output)?.group(0);
    if (result.exitCode != 0 || version == null)
      throw const ApiException('binary_probe_failed');
    return BinaryProbe(true, version);
  }

  @override
  Future<void> validate(ManagedCore core) async {
    if (!await File(core.binary).exists())
      throw const ApiException('binary_missing', status: 409);
    final result = await runner.run('/opt/sky-ui/current/bin/sky-ops', [
      'amnezia',
      'check',
      core.configuration,
    ]);
    if (result.exitCode != 0)
      throw const ApiException('configuration_invalid', status: 422);
  }

  @override
  Future<bool> controllerReady(ManagedCore core) async {
    if (!await super.controllerReady(core)) return false;
    try {
      final value =
          jsonDecode(await File(core.configuration).readAsString()) as Map;
      for (final interface in value['interfaces'] as List) {
        final name = interface['name'] as String;
        if (!RegExp(r'^skyawg[a-f0-9]{8}$').hasMatch(name) ||
            !await Directory('/sys/class/net/$name').exists())
          return false;
      }
      return true;
    } on Object {
      return false;
    }
  }
}
