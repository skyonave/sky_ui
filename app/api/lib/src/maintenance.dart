import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'errors.dart';
import 'process_runner.dart';

class MaintenanceService {
  MaintenanceService(
    this.runner, {
    this.directory = '/var/lib/sky-ui-maintenance',
    bool? supported,
  }) : supported = supported ?? Platform.isLinux;
  final CommandRunner runner;
  final String directory;
  final bool supported;
  bool _submitting = false;
  static final idPattern = RegExp(r'^[a-f0-9]{32}$');
  File get _request => File('$directory/inbox/request.json');
  bool get available => supported && Directory('$directory/inbox').existsSync();
  bool get busy {
    if (!available) return false;
    if (_submitting) return true;
    if (File('$directory/cleanup-intent.json').existsSync()) return true;
    if (File('$directory/restore-intent.json').existsSync() ||
        File('$directory/update-intent.json').existsSync() ||
        File('$directory/core-remove-intent.json').existsSync() ||
        File('$directory/engine-intent.json').existsSync() ||
        File('$directory/panel-update-intent.json').existsSync())
      return true;
    if (_request.existsSync()) return true;
    return _result()?.busy == true;
  }

  MaintenanceJob? _result() {
    final file = File('$directory/result.json');
    if (!file.existsSync()) return null;
    return MaintenanceJob.fromJson(
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
    );
  }

  Future<MaintenanceSnapshot> snapshot() async {
    final backups = <BackupInfo>[];
    if (available) {
      await for (final entry in Directory('$directory/backups').list()) {
        final name = entry.uri.pathSegments.last;
        if (entry is! File ||
            !name.endsWith('.json') ||
            !idPattern.hasMatch(name.substring(0, name.length - 5)))
          continue;
        backups.add(
          BackupInfo.fromJson(
            jsonDecode(await entry.readAsString()) as Map<String, dynamic>,
          ),
        );
      }
    }
    backups.sort((a, b) => b.created.compareTo(a.created));
    MaintenanceJob? job = _result();
    if (_request.existsSync()) {
      final request =
          jsonDecode(await _request.readAsString()) as Map<String, dynamic>;
      job = MaintenanceJob(
        id: request['id'] as String,
        action: request['action'] as String,
        status: 'queued',
        core: request['core'] as String?,
        tag: request['tag'] as String?,
      );
    }
    return MaintenanceSnapshot(
      available: available,
      backups: backups,
      job: job,
    );
  }

  Future<MaintenanceJob> submit(
    String action, {
    String? backupId,
    String? core,
    String? tag,
  }) async {
    if (busy) throw const ApiException('maintenance_busy', status: 409);
    _submitting = true;
    try {
      return await _submit(action, backupId: backupId, core: core, tag: tag);
    } finally {
      _submitting = false;
    }
  }

  Future<MaintenanceJob> _submit(
    String action, {
    String? backupId,
    String? core,
    String? tag,
  }) async {
    if (!available)
      throw const ApiException('maintenance_unavailable', status: 501);
    if (![
          'backup',
          'restore',
          'update',
          'install',
          'remove',
          'panel-update',
          'install-sni-scanner',
        ].contains(action) ||
        (action == 'restore' && !idPattern.hasMatch(backupId ?? '')) ||
        (action == 'remove' && !coreRepositories.containsKey(core)) ||
        (action == 'panel-update' &&
            !RegExp(
              r'^v[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.\-]+)?$',
            ).hasMatch(tag ?? '')) ||
        (['update', 'install'].contains(action) &&
            (!coreRepositories.containsKey(core) ||
                !RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag ?? '')))) {
      throw const ApiException('request_invalid', status: 400);
    }
    if (action == 'restore' &&
        !await File('$directory/backups/$backupId.tar.gz').exists()) {
      throw const ApiException('not_found', status: 404);
    }
    final service = action == 'panel-update'
        ? 'sky-ui-update.service'
        : 'sky-ui-maintenance.service';
    final worker = await runner.run('systemctl', [
      'is-active',
      '--quiet',
      service,
    ]);
    if (worker.exitCode == 0)
      throw const ApiException('maintenance_busy', status: 409);
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final payload = {
      'id': id,
      'action': action,
      if (action == 'restore') 'backupId': backupId,
      if (['update', 'install', 'remove'].contains(action)) 'core': core,
      if (['update', 'install', 'panel-update'].contains(action)) 'tag': tag,
    };
    final temporary = File('$directory/inbox/$id.tmp');
    await temporary.writeAsString(jsonEncode(payload), flush: true);
    await temporary.rename(_request.path);
    if (File('$directory/cleanup-intent.json').existsSync()) {
      await _request.delete();
      throw const ApiException('maintenance_busy', status: 409);
    }
    try {
      final result = await runner.run('systemctl', [
        'start',
        '--no-block',
        service,
      ]);
      if (result.exitCode != 0)
        throw const ApiException('maintenance_unavailable', status: 503);
    } on Object {
      if (await _request.exists()) await _request.delete();
      rethrow;
    }
    return MaintenanceJob(
      id: id,
      action: action,
      status: 'queued',
      core: core,
      tag: tag,
    );
  }

  Future<File> archive(String id) async {
    if (!idPattern.hasMatch(id))
      throw const ApiException('not_found', status: 404);
    final file = File('$directory/backups/$id.tar.gz');
    if (!await file.exists())
      throw const ApiException('not_found', status: 404);
    return file;
  }
}
