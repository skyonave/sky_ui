import 'dart:convert';
import 'dart:io';

import '../../infrastructure/process/command_runner.dart';
import '../../shared/api_exception.dart';
import '../contracts.dart';
import '../managed_core.dart';
import '../proxy/adapter.dart';

class AmneziaAdapter extends JsonProxyAdapter {
  AmneziaAdapter(CommandRunner runner, ProcessSupervisor supervisor)
    : super('amneziawg', runner, supervisor);
  @override
  String get name => 'AmneziaWG';
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
