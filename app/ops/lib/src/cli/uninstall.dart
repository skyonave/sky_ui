import 'dart:io';

import '../features/storage/retention.dart';
import '../platform/host.dart';
import 'context.dart';

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

List<String> panelRemovalAccounts({required bool nodeInstalled}) => [
  for (final name in accounts)
    if (!nodeInstalled || name != 'sky-ui-build') name,
];

/// The caller owns the node lifecycle lock and trusts the backup path.
Future<bool> restorePanelForwarding(
  File backup,
  File forwarding,
  Future<String?> Function() nodeState,
) async {
  final original = (await backup.readAsString()).trim();
  if (!['0', '1'].contains(original)) return false;
  final state = await nodeState();
  // Unknown or transitioning state must not disable another runtime's routing.
  if (state != 'inactive' && state != 'not-installed') return false;
  if ((await forwarding.readAsString()).trim() != '1') return false;
  await forwarding.writeAsString('$original\n');
  return true;
}

Future<void> _restoreForwarding() async {
  const backup = '/var/lib/sky-ui-amneziawg-network/ip_forward';
  if (!exists(backup)) return;
  host.trusted(backup);
  const nodeUnit = 'sky-ui-node-amneziawg.service';
  final hasNode = exists('/usr/local/libexec/sky-ui-node');
  final lock = hasNode ? HostLock('/run/lock/sky-ui-node.lock') : null;
  try {
    await lock?.acquire();
    await restorePanelForwarding(
      File(backup),
      File('/proc/sys/net/ipv4/ip_forward'),
      () async {
        if (!hasNode) return 'not-installed';
        try {
          final result = await command(
            ['systemctl', 'show', '-p', 'ActiveState', '--value', nodeUnit],
            check: false,
            timeout: const Duration(seconds: 5),
          );
          return result.exitCode == 0 ? result.stdout.toString().trim() : null;
        } on OpsError {
          return null;
        }
      },
    );
  } finally {
    lock?.close();
  }
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
    for (final unit in managedUnitFiles) '/etc/systemd/system/$unit',
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
  for (final unit in managedUnitFiles) {
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
    await _restoreForwarding();
    final removedAccounts = panelRemovalAccounts(
      nodeInstalled: exists('/usr/local/libexec/sky-ui-node'),
    );
    for (final name in removedAccounts.reversed)
      if ((await command(['id', '-u', name], check: false)).exitCode == 0)
        await run(['userdel', name]);
    for (final name in removedAccounts)
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
    for (final unit in managedUnitFiles) {
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
