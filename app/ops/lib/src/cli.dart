import 'dart:convert';
import 'dart:io';

import 'host.dart';
import 'artifacts.dart';
import 'backups.dart';
import 'maintenance.dart';
import 'releases.dart';
import 'storage.dart';

const accounts = [
  'sky-ui',
  'sky-ui-core',
  'sky-ui-sing-box',
  'sky-ui-xray',
  'sky-ui-build',
  'sky-ui-edge',
];
const directories = [
  etc,
  dataRoot,
  edge,
  '/var/lib/sky-ui-certificates',
  state,
  '/var/lib/sky-ui-amneziawg-network',
  '/opt/sky-ui',
  downloadCache,
];
Future<void> interactive(List<String> args, {bool check = true}) async {
  final p = await Process.start(
    args.first,
    args.skip(1).toList(),
    mode: ProcessStartMode.inheritStdio,
    environment: cleanEnvironment,
    includeParentEnvironment: false,
  );
  final code = await p.exitCode;
  require(!check || code == 0, 'command_failed');
}

String prompt(String question) {
  stdout.write(question);
  return stdin.readLineSync() ?? '';
}

void managed() {
  require(host.uid() == 0, 'root_required');
  host.trusted('$etc/managed-by-sky-ui');
}

Future<T> locked<T>(Future<T> Function() work) async {
  await waitCleanup();
  require(!exists('$state/panel-update-intent.json'), 'maintenance_busy');
  final install = HostLock('/run/lock/sky-ui-install.lock'),
      worker = HostLock('$state/worker.lock');
  try {
    await install.acquire();
    await worker.acquire();
    return await work();
  } finally {
    worker.close();
    install.close();
  }
}

Future<void> status() async {
  stdout.writeln('Sky UI / ${panelVersion()}');
  for (final unit in allUnits)
    stdout.writeln(
      '$unit: ${(await command(['systemctl', 'is-active', unit], check: false)).stdout.toString().trim()}',
    );
}

Future<void> lifecycle(String action, String target) async {
  require(
    ['start', 'stop', 'restart'].contains(action) &&
        ['panel', 'core', 'all', ...engineIds.skip(1)].contains(target),
    'request_invalid',
  );
  await locked(() async {
    final selected = target == 'all'
        ? engineIds
              .where((c) => File('$cores/$c/current/$c').existsSync())
              .toList()
        : target == 'core'
        ? ['mihomo']
        : engineIds.skip(1).contains(target)
        ? [target]
        : <String>[];
    final api = await active('sky-ui.service');
    if (selected.isNotEmpty && api)
      await run(['systemctl', 'stop', 'sky-ui.service']);
    try {
      if (selected.isNotEmpty) assertConfigurationSettled();
      final owner = await account('sky-ui');
      for (final core in selected) {
        require(
          action == 'stop' || File('$cores/$core/current/$core').existsSync(),
          'binary_missing',
        );
        final id = core == 'mihomo' ? 'primary' : core,
            path = '$dataRoot/instances/$id.json';
        if (!exists(parent(path)))
          host.mkdir(parent(path), mode: 0x1c0, uid: owner.uid, gid: owner.gid);
        final v = exists(path)
            ? readJson(path, 65536)
            : <String, dynamic>{'instanceId': id, 'coreId': core};
        require(v['instanceId'] == id && v['coreId'] == core, 'unsafe_file');
        await run(['systemctl', action, 'sky-ui-$core.service']);
        v['desiredState'] = action == 'stop' ? 'stopped' : 'running';
        atomicJson(path, v, mode: 0x180, uid: owner.uid, gid: owner.gid);
      }
    } finally {
      if (api && target != 'all' && selected.isNotEmpty) {
        await command([
          'systemctl',
          'reset-failed',
          'sky-ui.service',
        ], check: false);
        await run(['systemctl', 'start', 'sky-ui.service']);
      }
    }
    if (target == 'panel' || target == 'all')
      for (final unit
          in action == 'stop'
              ? ['sky-ui-edge.service', 'sky-ui.service']
              : ['sky-ui.service', 'sky-ui-edge.service']) {
        if (unit == 'sky-ui-edge.service' &&
            action != 'stop' &&
            !exists('$etc/Caddyfile')) {
          stdout.writeln('Для настройки HTTPS запусти skyui setup.');
          continue;
        }
        if (unit == 'sky-ui.service' && action != 'stop')
          await command(['systemctl', 'reset-failed', unit], check: false);
        await run(['systemctl', action, unit]);
      }
  });
  await status();
}

Future<void> logs(String target, {bool follow = false, int lines = 100}) async {
  final selected = switch (target) {
    'panel' => ['sky-ui.service', 'sky-ui-edge.service'],
    'all' => allUnits,
    'core' => ['sky-ui-mihomo.service'],
    'certificates' => ['sky-ui-edge.service', 'sky-ui-certificates.service'],
    _ =>
      engineIds.skip(1).contains(target)
          ? ['sky-ui-$target.service']
          : throw const OpsError('request_invalid'),
  };
  await interactive([
    'journalctl',
    '--namespace=+sky-ui',
    '--no-pager',
    '-n',
    '$lines',
    for (final u in selected) ...['-u', u],
    if (follow) '-f',
  ]);
}

Future<void> certificates(
  String action, {
  bool follow = false,
  int lines = 100,
}) async {
  require(
    ['status', 'setup', 'check', 'logs'].contains(action),
    'request_invalid',
  );
  if (action == 'setup')
    return interactive(['bash', '$current/deploy/setup.sh', 'setup']);
  if (action == 'logs')
    return logs('certificates', follow: follow, lines: lines);
  if (action == 'check') {
    await run(['systemctl', 'reload', 'sky-ui-edge.service']);
    await run(['systemctl', 'start', 'sky-ui-certificates.service']);
    stdout.writeln(
      'Настройки HTTPS применены, сертификаты синхронизированы с ядрами.',
    );
  }
  final access = exists('$etc/access.conf')
      ? readText('$etc/access.conf', 4096).split('\n')
      : <String>[];
  stdout.writeln('IP: ${access.isEmpty ? '—' : access.first}');
  stdout.writeln(
    'Домен: ${access.length > 1 && access[1].isNotEmpty ? access[1] : 'не настроен'}',
  );
  const root = '/var/lib/sky-ui-edge/data/caddy/certificates';
  var found = false;
  if (exists(root))
    for (final cert
        in Directory(root)
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((f) => f.path.endsWith('.crt'))) {
      found = true;
      stdout.writeln(basename(parent(cert.path)));
      await interactive([
        'openssl',
        'x509',
        '-in',
        cert.path,
        '-noout',
        '-subject',
        '-issuer',
        '-dates',
      ]);
    }
  if (!found)
    stdout.writeln('Выпущенных сертификатов пока нет. Проверь логи HTTPS.');
  stdout.writeln('Продлением управляет Caddy автоматически.');
  await interactive([
    'systemctl',
    'list-timers',
    'sky-ui-certificates.timer',
    '--no-pager',
  ]);
}

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

Future<List<String>> removalPlan() async {
  managed();
  require(
    environment()['SKY_UI_DATA_DIR'] == dataRoot,
    'external_data_directory',
  );
  if (exists(downloadCache))
    require(
      readText('$downloadCache/managed-by-sky-ui', 128).trim() ==
          downloadCacheMarker,
      'unmanaged_download_cache',
    );
  final owner = await account('sky-ui'), gateway = await account('sky-ui-edge');
  for (final path in directories)
    if (exists(path))
      host.trusted(
        path,
        directory: true,
        uid: path == dataRoot
            ? owner.uid
            : path == edge
            ? gateway.uid
            : 0,
        writable: path == dataRoot || path == edge,
      );
  const journal = '/etc/systemd/journald@sky-ui.conf';
  if (exists(journal))
    require(
      isLink(journal) &&
          Link(journal).targetSync() == '$current/deploy/journald-sky-ui.conf',
      'unmanaged_journal',
    );
  final files = [
    for (final unit in allUnits) '/etc/systemd/system/$unit',
    '/etc/polkit-1/rules.d/49-sky-ui.rules',
    '/run/lock/sky-ui-install.lock',
    '/run/lock/sky-ui-setup.lock',
  ];
  const cachePolicy = '/etc/tmpfiles.d/sky-ui-install.conf';
  if (exists(cachePolicy)) {
    host.trusted(cachePolicy);
    require(
      readText(
        cachePolicy,
        4096,
      ).startsWith('# Sky UI verified download retry cache.'),
      'unmanaged_download_cache',
    );
    files.add(cachePolicy);
  }
  for (final name in ['skyui', 'sky-ui']) {
    final path = '/usr/local/bin/$name';
    if (exists(path)) {
      host.trusted(path);
      final content = readText(path);
      require(
        content.contains('$current/deploy/') ||
            content.contains('$current/bin/sky-ops'),
        'unmanaged_command',
      );
    }
    files.add(path);
  }
  for (final unit in allUnits) {
    final path = '/etc/systemd/system/$unit';
    if (exists(path)) {
      host.trusted(path);
      require(readText(path, 65536).contains('Sky UI'), 'unmanaged_service');
    }
    if (exists('$path.d')) host.trusted('$path.d', directory: true);
  }
  for (final path in files) if (exists(path)) host.trusted(path);
  final passwd = (await run(['getent', 'passwd']))
          .trim()
          .split('\n')
          .map((l) => l.split(':'))
          .toList(),
      groups = (await run(['getent', 'group']))
          .trim()
          .split('\n')
          .map((l) => l.split(':'))
          .toList();
  for (final user in passwd.where((u) => accounts.contains(u[0]))) {
    require(
      user[2] != '0' &&
          user[3] != '0' &&
          [
            '/usr/sbin/nologin',
            '/sbin/nologin',
            '/bin/false',
          ].contains(user[6]),
      'unmanaged_account',
    );
    require(
      !passwd.any((u) => !accounts.contains(u[0]) && u[3] == user[3]),
      'shared_account_group',
    );
  }
  for (final group in groups.where((g) => accounts.contains(g[0])))
    require(
      group[3].split(',').where((s) => s.isNotEmpty).every(accounts.contains),
      'shared_account_group',
    );
  return files;
}

Future<void> uninstall() async {
  await removalPlan();
  stdout.writeln(
    'Будут удалены Sky UI, ядра, настройки, доступы, пароли, сертификаты и резервные копии:',
  );
  for (final path in directories) stdout.writeln('  $path');
  if (prompt('Введите DELETE для полного удаления: ').trim() != 'DELETE') {
    stdout.writeln('Удаление отменено.');
    return;
  }
  await locked(() async {
    final files = await removalPlan();
    for (final unit in allUnits)
      await command(['systemctl', 'disable', '--now', unit], check: false);
    for (final unit in allUnits)
      require(
        !['active', 'activating', 'deactivating', 'reloading'].contains(
          (await command([
            'systemctl',
            'is-active',
            unit,
          ], check: false)).stdout.toString().trim(),
        ),
        'service_stop_timeout',
      );
    const forwarding = '/var/lib/sky-ui-amneziawg-network/ip_forward';
    if (exists(forwarding)) {
      host.trusted(forwarding);
      final original = readText(forwarding, 16).trim();
      if (['0', '1'].contains(original) &&
          File('/proc/sys/net/ipv4/ip_forward').readAsStringSync().trim() ==
              '1')
        File('/proc/sys/net/ipv4/ip_forward').writeAsStringSync('$original\n');
    }
    for (final name in accounts.reversed)
      if ((await command(['id', '-u', name], check: false)).exitCode == 0)
        await run(['userdel', name]);
    for (final name in accounts)
      if ((await command(['getent', 'group', name], check: false)).exitCode ==
          0)
        await run(['groupdel', name]);
    await command([
      'systemctl',
      'stop',
      'systemd-journald@sky-ui.service',
      'systemd-journald@sky-ui.socket',
      'systemd-journald-varlink@sky-ui.socket',
    ], check: false);
    final machine = File('/etc/machine-id').readAsStringSync().trim();
    if (RegExp(r'^[a-f0-9]{32}$').hasMatch(machine)) {
      final journal = '/var/log/journal/$machine.sky-ui';
      if (exists(journal)) {
        host.trusted(journal, directory: true);
        host.deleteTree(journal);
      }
    }
    for (final path in files) if (!path.startsWith('/run/lock/')) unlink(path);
    unlink('/etc/systemd/journald@sky-ui.conf');
    for (final unit in allUnits) {
      final dropin = '/etc/systemd/system/$unit.d';
      if (exists(dropin)) host.deleteTree(dropin);
    }
    await run(['systemctl', 'daemon-reload']);
    for (final unit in allUnits)
      await command(['systemctl', 'reset-failed', unit], check: false);
    final references = Retention().references();
    for (final directory in Directory(
      '/var/tmp',
    ).listSync(followLinks: false).whereType<Directory>()) {
      if (!managedTemporaryPattern.hasMatch(basename(directory.path)) ||
          references.any((p) => within(p, directory.path)) ||
          !rootOwnedDirectory(directory.path))
        continue;
      host.deleteTree(directory.path);
    }
    for (final path in directories) if (exists(path)) host.deleteTree(path);
    for (final path in files.where((p) => p.startsWith('/run/lock/')))
      unlink(path);
  });
  stdout.writeln(
    'Sky UI удалён. Системные зависимости и общая история journalctl сохранены.',
  );
}

Future<void> cliMain(List<String> args) async {
  if (args.isEmpty || ['--help', '-h'].contains(args.first)) {
    stdout.writeln(
      'Sky UI: status, version, setup, start|stop|restart [panel|core|all|sing-box|xray|amneziawg],\nlogs [target] [-f] [-n 100], certificates [status|setup|check|logs],\nbackup, backups, restore ID, install-core|update-core|remove-core [engine], update, cleanup, uninstall',
    );
    return;
  }
  managed();
  final action = args.first;
  if ([
    'backup',
    'backups',
    'restore',
    'install-core',
    'update-core',
    'remove-core',
    'update',
  ].contains(action))
    return maintenanceCli(args);
  if (['start', 'stop', 'restart'].contains(action)) {
    require(args.length <= 2, 'request_invalid');
    return lifecycle(action, args.length == 2 ? args[1] : 'panel');
  }
  switch (action) {
    case 'version':
      stdout.writeln(panelVersion());
    case 'status':
      await status();
    case 'setup':
      await interactive(['bash', '$current/deploy/setup.sh', 'setup']);
    case 'cleanup':
      await run(['systemctl', 'start', 'sky-ui-cleanup.service']);
      stdout.writeln(
        'Свободно: ${((await freeBytes(state)) / 1073741824).toStringAsFixed(1)} GB',
      );
    case 'uninstall':
      await uninstall();
    case 'logs':
    case 'certificates':
      var target = action == 'logs' ? 'panel' : 'status',
          follow = false,
          lines = 100;
      for (var i = 1; i < args.length; i++) {
        final a = args[i];
        if (a == '-f' || a == '--follow')
          follow = true;
        else if (a == '-n' || a == '--lines') {
          require(i + 1 < args.length, 'request_invalid');
          lines = int.parse(args[++i]);
        } else {
          require(i == 1, 'request_invalid');
          target = a;
        }
      }
      require(lines >= 1 && lines <= 10000, 'request_invalid');
      if (action == 'logs')
        await logs(target, follow: follow, lines: lines);
      else
        await certificates(target, follow: follow, lines: lines);
    default:
      throw const OpsError('request_invalid');
  }
}
