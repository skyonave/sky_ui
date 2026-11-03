import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../../platform/host.dart';
import '../../shared/archives.dart';

void assertConfigurationSettled() {
  if (!exists('$dataRoot/panel.sqlite')) return;
  host.read('$dataRoot/panel.sqlite');
  final db = sqlite3.open('$dataRoot/panel.sqlite', mode: OpenMode.readOnly);
  try {
    require(
      db.select('SELECT count(*) FROM deployment').first.values.first == 0,
      'configuration_recovery_required',
    );
  } finally {
    db.close();
  }
}

Future<void> databaseCopy(
  String source,
  String target, {
  bool sessions = true,
}) async {
  host.read(source);
  require(!exists(target), 'unsafe_file');
  final db = sqlite3.open(source, mode: OpenMode.readOnly),
      copy = sqlite3.open(target);
  try {
    await db.backup(copy, nPage: -1).drain<void>();
    if (!sessions) copy.execute('DELETE FROM sessions');
    require(
      copy.select('PRAGMA integrity_check').first.values.first == 'ok',
      'database_invalid',
    );
  } finally {
    copy.close();
    db.close();
  }
}

Future<Map<String, Uint8List>> snapshotFiles({bool sessions = false}) async {
  final files = <String, Uint8List>{};
  await temporary('$state/work', 'tmp', (work) async {
    for (final name in ['panel', 'owner']) {
      await databaseCopy(
        '$dataRoot/$name.sqlite',
        '$work/$name.sqlite',
        sessions: name != 'owner' || sessions,
      );
      files['data/$name.sqlite'] = host.read('$work/$name.sqlite');
    }
  });
  for (final name in [
    'instances/primary.json',
    'cores/mihomo/config.yaml',
    for (final core in engineIds.skip(1)) ...[
      'instances/$core.json',
      'cores/$core/config.json',
    ],
  ])
    if (exists('$dataRoot/$name'))
      files['data/$name'] = host.read('$dataRoot/$name');
  for (final file in Directory(etc).listSync(followLinks: false))
    if (validBackupMember('etc/${basename(file.path)}') && file is File)
      files['etc/${basename(file.path)}'] = host.read(file.path);
  if (exists('$edge/data'))
    for (final file in Directory(
      '$edge/data',
    ).listSync(recursive: true, followLinks: false)) {
      require(file is! Link, 'unsafe_file');
      if (file is File) {
        files['edge/${file.path.substring(edge.length + 1)}'] = host.read(
          file.path,
        );
        require(
          files.length <= 2048 &&
              files.values.fold<int>(0, (n, b) => n + b.length) <=
                  128 * 1024 * 1024,
          'backup_too_large',
        );
      }
    }
  return files;
}

Future<Map<String, dynamic>> createBackup(
  int gid, {
  String purpose = 'manual',
}) async {
  final id = randomId();
  var coreVersion = 'not installed';
  if (File('$cores/mihomo/current/mihomo').existsSync())
    coreVersion = (await run([
      'runuser',
      '-u',
      'sky-ui-core',
      '--',
      '$cores/mihomo/current/mihomo',
      '-v',
    ])).split('\n').first;
  final metadata = {
    'id': id,
    'purpose': purpose,
    'created': now(),
    'version': panelVersion(),
    'machine': digest(host.read('/etc/machine-id', limit: 256)),
    'coreVersion': coreVersion,
  };
  final packed = packBackup(await snapshotFiles(), metadata);
  host.atomic('$state/backups/$id.tar.gz', packed.bytes, gid: gid);
  final public = <String, dynamic>{...metadata}..remove('machine');
  public.addAll({'size': packed.bytes.length, 'sha256': digest(packed.bytes)});
  atomicJson('$state/backups/$id.json', public, gid: gid);
  return public;
}

Future<void> applyFiles(Map<String, List<int>> files, int gid) async {
  final owner = await account('sky-ui'),
      gateway = await account('sky-ui-edge'),
      core = await account('sky-ui-core');
  for (final name in ['panel.sqlite', 'owner.sqlite'])
    for (final suffix in ['-wal', '-shm']) unlink('$dataRoot/$name$suffix');
  for (final entry in files.entries) {
    require(validBackupMember(entry.key), 'backup_path_invalid');
    final area = entry.key.split('/').first,
        relative = entry.key.substring(area.length + 1),
        base = {'data': dataRoot, 'etc': etc, 'edge': edge}[area]!;
    final path = '$base/$relative';
    if (area == 'edge') {
      var dir = base;
      for (final component
          in relative.split('/').take(relative.split('/').length - 1)) {
        dir = '$dir/$component';
        host.mkdir(dir, mode: 0x1c0, uid: gateway.uid, gid: gateway.gid);
      }
      host.atomic(
        path,
        entry.value,
        mode: 0x180,
        uid: gateway.uid,
        gid: gateway.gid,
      );
    } else if (entry.key == 'etc/Caddyfile')
      host.atomic(path, entry.value, gid: gateway.gid);
    else if (entry.key == 'etc/controller.secret')
      host.atomic(path, entry.value, gid: gid);
    else if (entry.key == 'data/cores/mihomo/config.yaml')
      host.atomic(path, entry.value, mode: 0x1b0, uid: core.uid, gid: gid);
    else if (entry.key.startsWith('data/cores/') &&
        entry.key.endsWith('/config.json'))
      host.atomic(path, entry.value, mode: 0x1b0, uid: owner.uid, gid: gid);
    else if ([
      'etc/server.env',
      'etc/admin.hash',
      'etc/access.conf',
      'etc/managed-by-sky-ui',
    ].contains(entry.key))
      host.atomic(path, entry.value, mode: 0x180, gid: 0);
    else
      host.atomic(path, entry.value, mode: 0x180, uid: owner.uid, gid: gid);
  }
}

Future<void> apiReady(Map<String, String> env) async {
  for (var n = 0; n < 60; n++) {
    try {
      final value = jsonDecode(
        utf8.decode(
          await httpBytes(
            'http://127.0.0.1:${env['SKY_UI_PORT']}/api/v1/health',
            65536,
            official: false,
            timeout: const Duration(seconds: 2),
          ),
        ),
      );
      if (value['status'] == 'ok') return;
    } on Object {
      /* Retry while starting. */
    }
    await sleep(250);
  }
  throw const OpsError('api_not_ready');
}

Future<void> controllerReady(Map<String, String> env, {String? version}) async {
  final secret = readText(env['SKY_UI_CONTROLLER_SECRET_FILE']!, 256).trim(),
      end = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(end)) {
    try {
      final value = jsonDecode(
        utf8.decode(
          await httpBytes(
            '${env['SKY_UI_CONTROLLER_URL'] ?? 'http://127.0.0.1:19090'}/version',
            65536,
            headers: {'Authorization': 'Bearer $secret'},
            official: false,
            timeout: const Duration(seconds: 2),
          ),
        ),
      );
      if (version == null ||
          '${value['version']}'.replaceFirst(RegExp(r'^v'), '') ==
              version.replaceFirst(RegExp(r'^v'), ''))
        return;
    } on Object {
      /* Retry while starting. */
    }
    await sleep(250);
  }
  throw const OpsError('controller_not_ready');
}
