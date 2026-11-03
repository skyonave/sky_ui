import 'dart:io';

import '../../application/access/records.dart' show digest;
import '../../application/contracts/configuration_store.dart';
import '../../engines/managed_core.dart';
import '../../shared/api_exception.dart';

class ConfigurationFiles implements ConfigurationStore {
  const ConfigurationFiles(this.dataDirectory);
  final String dataDirectory;
  @override
  Future<String?> read(ManagedCore core) async {
    final file = File(core.configuration);
    return await file.exists() ? await file.readAsString() : null;
  }

  @override
  Future<bool> matches(ManagedCore core, String expectedHash) async {
    try {
      return digest(await File(core.configuration).readAsString()) ==
          expectedHash;
    } on FileSystemException {
      return false;
    }
  }

  @override
  Future<T> stage<T>(
    String text,
    String name,
    Future<T> Function(String) action,
  ) async {
    final root = await Directory(
      '${dataDirectory}/staging',
    ).create(recursive: true);
    final parent = await root.resolveSymbolicLinks();
    final temporary = await Directory(parent).createTemp('deployment-');
    final resolved = await temporary.resolveSymbolicLinks();
    if (!resolved.startsWith('$parent${Platform.pathSeparator}'))
      throw StateError('Invalid staging directory.');
    try {
      final file = File('$resolved/$name');
      await file.writeAsString(text, flush: true);
      if (Platform.isLinux) {
        final result = await Process.run('/usr/bin/chmod', ['0640', file.path]);
        if (result.exitCode != 0)
          throw const ApiException('configuration_write_failed', status: 500);
      }
      return await action(file.path);
    } finally {
      final target = await temporary.resolveSymbolicLinks();
      if (target != resolved ||
          !target.startsWith('$parent${Platform.pathSeparator}'))
        throw StateError('Unsafe staging cleanup.');
      await temporary.delete(recursive: true);
    }
  }

  @override
  Future<void> publish(String text, ManagedCore core) =>
      stage(text, 'published.yaml', (file) async {
        await File(file).rename(core.configuration);
      });
}
