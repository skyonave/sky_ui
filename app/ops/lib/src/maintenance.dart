import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'host.dart';
import 'artifacts.dart';
import 'archives.dart';
import 'backups.dart';
import 'engines.dart';
import 'amnezia.dart';
import 'certificates.dart';
import 'progress.dart';
import 'panel_update.dart';
import 'sni_tool.dart';

const intentNames = [
  'restore-intent.json',
  'update-intent.json',
  'core-remove-intent.json',
  'engine-intent.json',
  'panel-update-intent.json',
];
Map<String, dynamic> consumeRequest(int uid, {bool remove = true}) {
  const path = '$state/inbox/request.json';
  final value = object(
    jsonDecode(utf8.decode(host.read(path, limit: 4096, uid: uid))),
  );
  const keys = {
    'backup': {'id', 'action'},
    'restore': {'id', 'action', 'backupId'},
    'update': {'id', 'action', 'core', 'tag'},
    'install': {'id', 'action', 'core', 'tag'},
    'remove': {'id', 'action', 'core'},
    'panel-update': {'id', 'action', 'tag'},
    'install-sni-scanner': {'id', 'action'},
  };
  final action = value['action'];
  require(
    value['id'] is String &&
        identityPattern.hasMatch(value['id']) &&
        keys.containsKey(action),
    'request_invalid',
  );
  require(
    value.length == keys[action]!.length &&
        keys[action]!.every(value.containsKey),
    'request_invalid',
  );
  if (action == 'restore')
    require(
      value['backupId'] is String &&
          identityPattern.hasMatch(value['backupId']),
      'request_invalid',
    );
  if (['update', 'install', 'remove'].contains(action))
    require(repositories.containsKey(value['core']), 'request_invalid');
  if (['update', 'install'].contains(action))
    require(
      value['tag'] is String && coreTagPattern.hasMatch(value['tag']),
      'request_invalid',
    );
  if (action == 'panel-update')
    require(
      value['tag'] is String &&
          (value['tag'] as String).startsWith('v') &&
          parseVersion(value['tag']) != null,
      'request_invalid',
    );
  if (remove) unlink(path);
  return value;
}

Future<Map<String, dynamic>> restoreBackup(String id, int gid) async {
  require(identityPattern.hasMatch(id), 'backup_invalid');
  final backup = unpackBackup(host.read('$state/backups/$id.tar.gz'));
  final files = backup.files, manifest = backup.manifest;
  require(
    manifest['machine'] == digest(host.read('/etc/machine-id', limit: 256)),
    'backup_wrong_host',
  );
  require(manifest['version'] == panelVersion(), 'backup_version_mismatch');
  await temporary('$state/work', 'tmp', (work) async {
    for (final name in ['panel', 'owner']) {
      final path = '$work/$name.sqlite';
      host.atomic(path, files['data/$name.sqlite']!, mode: 0x180);
      final db = sqlite3.open(path);
      try {
        require(
          db.select('PRAGMA integrity_check').first.values.first == 'ok',
          'database_invalid',
        );
        require(
          db.select('PRAGMA user_version').first.values.first == 1,
          'database_version_invalid',
        );
        if (name == 'owner') db.execute('DELETE FROM sessions');
      } finally {
        db.close();
      }
      if (name == 'owner') files['data/owner.sqlite'] = host.read(path);
    }
  });
  const staging = '$state/validation';
  host.mkdir(staging, mode: 0x1e8, gid: gid);
  for (final core in engineIds) {
    final name =
        'data/cores/$core/${core == 'mihomo' ? 'config.yaml' : 'config.json'}';
    if (!files.containsKey(name)) continue;
    final path = '$staging/${core == 'mihomo' ? 'config.yaml' : '$core.json'}';
    host.atomic(path, files[name]!, gid: gid);
    if (core == 'amneziawg')
      loadAwg(path);
    else if (File('$cores/$core/current/$core').existsSync())
      await validateEngine(
        core,
        '$cores/$core/current/$core',
        configuration: path,
      );
  }
  final rescue = await createBackup(gid, purpose: 'rescue'),
      previous = await snapshotFiles(),
      running = <String, bool>{
        for (final unit in units) unit: await active(unit),
      };
  final timer = await active('sky-ui-certificates.timer');
  await run([
    'systemctl',
    'stop',
    'sky-ui-certificates.timer',
    'sky-ui-certificates.service',
  ]);
  atomicJson('$state/restore-intent.json', {'backupId': rescue['id']});
  Future<void> startPrevious() async {
    for (final unit in units.reversed)
      if (running[unit]!) await run(['systemctl', 'start', unit]);
    for (final core in engineIds)
      if (running['sky-ui-$core.service']!) await awaitEngineReady(core);
  }

  try {
    for (final unit in units.reversed) await run(['systemctl', 'stop', unit]);
    await applyFiles(files, gid);
    await syncCertificates();
    await startPrevious();
    if (running['sky-ui.service']!) await apiReady(environment());
    unlink('$state/restore-intent.json');
    return {'restored': id, 'rescueBackup': rescue['id']};
  } on Object {
    for (final unit in units.reversed) await run(['systemctl', 'stop', unit]);
    await applyFiles(previous, gid);
    await startPrevious();
    unlink('$state/restore-intent.json');
    throw const OpsError('restore_rolled_back');
  } finally {
    for (final name in [
      'config.yaml',
      for (final core in engineIds.skip(1)) '$core.json',
    ])
      unlink('$staging/$name');
    if (timer) await run(['systemctl', 'start', 'sky-ui-certificates.timer']);
  }
}

Future<void> recoverMaintenance(int gid) async {
  const engineIntent = '$state/engine-intent.json';
  if (exists(engineIntent)) {
    final v = readJson(engineIntent, 4096), core = v['core'];
    require(engineIds.skip(1).contains(core), 'request_invalid');
    if (v['action'] == 'remove')
      await changeEngine('remove', core as String, null, gid);
    else {
      final previous = v['previous'] as String?;
      if (previous != null) {
        require(parent(previous) == '$cores/$core', 'unsafe_file');
        host.trusted(previous, directory: true);
        switchLink('$cores/$core/current', previous);
      } else
        unlink('$cores/$core/current');
      if (v['running'] == true) await restartReady(core as String);
      unlink(engineIntent);
    }
  }
  await recoverPanel(gid);
  if (exists('$state/core-remove-intent.json')) {
    final v = readJson('$state/core-remove-intent.json', 4096);
    require(v.length == 1 && v['core'] == 'mihomo', 'request_invalid');
    await changeEngine('remove', 'mihomo', null, gid);
  }
  if (exists('$state/restore-intent.json')) {
    final id = readJson('$state/restore-intent.json', 1024)['backupId'];
    require(id is String && identityPattern.hasMatch(id), 'backup_invalid');
    await applyFiles(
      unpackBackup(host.read('$state/backups/$id.tar.gz')).files,
      gid,
    );
    unlink('$state/restore-intent.json');
  }
  if (exists('$state/update-intent.json')) {
    final value = readJson('$state/update-intent.json', 4096),
        previous = value['path'] as String?;
    if (previous != null) {
      final path = resolved(previous);
      require(
        within(path, releases) || within(path, '$cores/mihomo'),
        'unsafe_file',
      );
      host.trusted(path, directory: true);
      switchLink('$cores/mihomo/current', path);
    } else
      unlink('$cores/mihomo/current');
    unlink('$state/update-intent.json');
  }
  if (exists('$state/result.json')) {
    final value = readJson('$state/result.json', 16384);
    if (value['status'] == 'running') {
      value.addAll({'status': 'failed', 'error': 'maintenance_interrupted'});
      atomicJson('$state/result.json', value, gid: gid);
    }
  }
}

Future<void> waitCleanup() async {
  final end = DateTime.now().add(const Duration(seconds: 30));
  while (true) {
    String status;
    try {
      status = (await run([
        'systemctl',
        'show',
        'sky-ui-cleanup.service',
        '--property=ActiveState',
        '--value',
      ])).trim();
    } on OpsError {
      if (exists('$state/cleanup-intent.json')) rethrow;
      return;
    }
    if (!exists('$state/cleanup-intent.json') &&
        !['active', 'activating', 'deactivating'].contains(status))
      return;
    require(DateTime.now().isBefore(end), 'maintenance_busy');
    await sleep();
  }
}

Future<void> maintenanceMain(
  List<String> args, {
  Fetch? fetch,
  Future<Uint8List> Function(Uint8List, String, String, Reporter?)? compileAwg,
}) async {
  require(host.uid() == 0, 'root_required');
  host.umask(0x3f);
  final owner = await account('sky-ui');
  final lock = HostLock('$state/worker.lock');
  try {
    await lock.acquire();
    if (args.length == 1 && args.first == '--recover') {
      unlink('$state/cleanup-intent.json');
      await recoverMaintenance(owner.gid);
      return;
    }
    require(
      !intentNames.any((n) => exists('$state/$n')),
      'maintenance_recovery_required',
    );
    final job = consumeRequest(owner.uid, remove: false);
    require(job['action'] != 'panel-update', 'request_invalid');
    final result = <String, dynamic>{
      'id': job['id'],
      'action': job['action'],
      'status': 'running',
      if (job.containsKey('core')) 'core': job['core'],
      if (job.containsKey('tag')) 'tag': job['tag'],
    };
    atomicJson('$state/result.json', result, gid: owner.gid);
    unlink('$state/inbox/request.json');
    final api = await active('sky-ui.service');
    var stopped = false;
    final reporter =
        ['install', 'update', 'install-sni-scanner'].contains(job['action'])
        ? Reporter(
            result,
            null,
            job['action'] == 'install-sni-scanner'
                ? sniToolVersion
                : job['tag'] as String,
            owner.gid,
          )
        : null;
    Future<void> beforeActivation() async {
      if (api && !stopped) {
        await run(['systemctl', 'stop', 'sky-ui.service']);
        stopped = true;
      }
      assertConfigurationSettled();
    }

    try {
      if (reporter == null) {
        if (api) await beforeActivation();
        assertConfigurationSettled();
      }
      result['data'] = switch (job['action']) {
        'backup' => await createBackup(owner.gid),
        'restore' => await restoreBackup(job['backupId'] as String, owner.gid),
        'install-sni-scanner' => await installSniTool(reporter!, fetch: fetch),
        _ => await changeEngine(
          job['action'] as String,
          job['core'] as String,
          job['tag'] as String?,
          owner.gid,
          reporter: reporter,
          beforeActivation: beforeActivation,
          fetch: fetch,
          compileAwg: compileAwg,
        ),
      };
      result['status'] = 'completed';
    } on Object catch (error, trace) {
      if (error is! OpsError) stderr.writeln('${error.runtimeType}\n$trace');
      final code = error is OpsError ? error.code : 'maintenance_failed';
      result.addAll({'status': 'failed', 'error': code});
      reporter?.failed(code, {'failedStage': reporter.progress['stage']});
    } finally {
      if (stopped && !intentNames.take(4).any((n) => exists('$state/$n'))) {
        try {
          await command([
            'systemctl',
            'reset-failed',
            'sky-ui.service',
          ], check: false);
          await run(['systemctl', 'start', 'sky-ui.service']);
          await apiReady(environment());
        } on Object {
          result.addAll({'status': 'failed', 'error': 'api_not_ready'});
          reporter?.failed('api_not_ready', {'failedStage': 'health'});
        }
      }
      if (reporter != null && result['status'] == 'completed') {
        reporter.progress['finishedAt'] = now();
        reporter.stage('complete');
      }
      atomicJson('$state/result.json', result, gid: owner.gid);
    }
  } finally {
    lock.close();
  }
}
