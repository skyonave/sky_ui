import 'dart:convert';
import 'dart:io';

import '../features/maintenance/worker.dart';
import '../features/updates/release_catalog.dart';
import '../platform/host.dart';
import '../shared/artifacts.dart';
import 'context.dart';

Future<void> maintenanceCli(List<String> args) async {
  final owner = await account('sky-ui'), action = args.first;
  if (action == 'backups') {
    for (final f
        in Directory('$state/backups')
            .listSync(followLinks: false)
            .whereType<File>()
            .where((f) => f.path.endsWith('.json'))) {
      final v = readJson(f.path, 4096);
      stdout.writeln('${v['id']} ${v['created']} ${v['version']} ${v['size']}');
    }
    return;
  }
  Map<String, dynamic> job;
  if (action == 'update') {
    final release = await candidate(panelVersion(), targetPlatform());
    if (release == null) {
      stdout.writeln('Обновлений Sky UI нет.');
      return;
    }
    stdout.writeln('Sky UI: ${panelVersion()} → ${release['tag']}');
    require(prompt('Введите UPDATE для обновления: ') == 'UPDATE', 'cancelled');
    job = {'action': 'panel-update', 'tag': release['tag']};
  } else if (action == 'backup') {
    require(args.length == 1, 'request_invalid');
    job = {'action': 'backup'};
  } else if (action == 'restore') {
    require(
      args.length == 2 && identityPattern.hasMatch(args[1]),
      'request_invalid',
    );
    stdout.writeln(
      'Восстановление заменит данные и настройки, завершит сеансы и перезапустит службы.',
    );
    require(
      prompt('Введите RESTORE для продолжения: ') == 'RESTORE',
      'cancelled',
    );
    job = {'action': 'restore', 'backupId': args[1]};
  } else {
    require(
      ['install-core', 'update-core', 'remove-core'].contains(action) &&
          args.length <= 2,
      'request_invalid',
    );
    final core = args.length == 2 ? args[1] : 'mihomo';
    require(engineIds.contains(core), 'request_invalid');
    final operation = action.replaceFirst('-core', '');
    final release = operation == 'remove'
        ? null
        : await verifiedRelease(core, panelVersion(), targetPlatform());
    stdout.writeln(
      '$operation $core ${release?.tag ?? ''}. Подключения и ключи сохранятся.',
    );
    require(
      prompt('Введите ${operation.toUpperCase()} для продолжения: ') ==
          operation.toUpperCase(),
      'cancelled',
    );
    job = {
      'action': operation,
      'core': core,
      if (release != null) 'tag': release.tag,
    };
  }
  await waitCleanup();
  final previous = exists('$state/result.json')
      ? readJson('$state/result.json')
      : {};
  require(
    !['running', 'queued'].contains(previous['status']) &&
        !exists('$state/inbox/request.json') &&
        !await active('sky-ui-maintenance.service') &&
        !exists('$state/panel-update-intent.json'),
    'maintenance_busy',
  );
  job['id'] = randomId();
  atomicJson(
    '$state/inbox/request.json',
    job,
    mode: 0x180,
    uid: owner.uid,
    gid: owner.gid,
  );
  try {
    await waitCleanup();
  } on Object {
    if (exists('$state/inbox/request.json') &&
        readJson('$state/inbox/request.json')['id'] == job['id'])
      unlink('$state/inbox/request.json');
    rethrow;
  }
  final service = job['action'] == 'panel-update'
      ? 'sky-ui-update.service'
      : 'sky-ui-maintenance.service';
  await run(['systemctl', 'start', '--no-block', service]);
  stdout.writeln('Job: ${job['id']}');
  final started = DateTime.now(),
      deadline = started.add(const Duration(minutes: 35));
  while (DateTime.now().isBefore(deadline)) {
    if (exists('$state/result.json')) {
      final result = readJson('$state/result.json');
      if (result['id'] == job['id'] &&
          !['queued', 'running'].contains(result['status'])) {
        // A published receipt can precede the unit's lock release/cleanup by a
        // few milliseconds. Returning early makes the next CLI action race it.
        final settled = DateTime.now().add(const Duration(seconds: 30));
        while (['active', 'activating', 'deactivating'].contains(
          (await run([
            'systemctl',
            'show',
            service,
            '--property=ActiveState',
            '--value',
          ])).trim(),
        )) {
          require(DateTime.now().isBefore(settled), 'maintenance_busy');
          await sleep(100);
        }
        await waitCleanup();
        stdout.writeln(jsonEncode(result));
        require(
          result['status'] == 'completed',
          result['error'] as String? ?? 'maintenance_failed',
        );
        return;
      }
    }
    if (DateTime.now().difference(started).inSeconds > 5 &&
        (await run([
              'systemctl',
              'show',
              '-p',
              'ActiveState',
              '--value',
              service,
            ])).trim() ==
            'failed') {
      if (exists('$state/inbox/request.json') &&
          readJson('$state/inbox/request.json')['id'] == job['id'])
        unlink('$state/inbox/request.json');
      throw const OpsError('maintenance_service_failed');
    }
    await sleep(500);
  }
  throw const OpsError('maintenance_timeout');
}
