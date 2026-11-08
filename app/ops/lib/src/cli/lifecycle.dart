import 'dart:io';

import '../features/backups/backups.dart';
import '../platform/host.dart';
import 'context.dart';

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
    'panel' => [
      'sky-ui.service',
      'sky-ui-edge.service',
      'sky-ui-systemd-control@*.service',
    ],
    'all' => [...allUnits, 'sky-ui-systemd-control@*.service'],
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
