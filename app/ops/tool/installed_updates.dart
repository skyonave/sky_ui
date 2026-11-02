import 'dart:io';

import 'package:sky_ui_ops/src/host.dart';
import 'package:sky_ui_ops/src/backups.dart';

import 'installed_acceptance.dart' show Client, isolated;

Future<void> exercisePanelUpdates(Client client) async {
  isolated();
  final owner = await account('sky-ui');
  Future<String> queue(String version) async {
    final id = randomId();
    atomicJson(
      '$state/inbox/request.json',
      {'id': id, 'action': 'panel-update', 'tag': 'v$version'},
      mode: 0x180,
      uid: owner.uid,
      gid: owner.gid,
    );
    await command([
      'systemctl',
      'reset-failed',
      'sky-ui-update.service',
    ], check: false);
    await run(['systemctl', 'start', '--no-block', 'sky-ui-update.service']);
    return id;
  }

  Future<Map<String, dynamic>> finish(String id) async {
    final end = DateTime.now().add(const Duration(minutes: 3));
    while (DateTime.now().isBefore(end)) {
      final result = exists('$state/result.json')
          ? readJson('$state/result.json')
          : <String, dynamic>{};
      if (result['id'] == id &&
          !['running', 'queued'].contains(result['status']))
        return result;
      await sleep(150);
    }
    throw const OpsError('fixture_update_timeout');
  }

  var result = await finish(await queue('0.8.0-dev.2'));
  require(
    result['status'] == 'completed' && panelVersion() == '0.8.0-dev.2',
    'fixture_panel_update_failed_${result['error']}',
  );
  await apiReady(environment());
  require(
    (await client.call('auth/session'))['data']['authenticated'] == true,
    'panel_update_revoked_session',
  );
  final selected = resolved(current);
  result = await finish(await queue('0.8.0-dev.3'));
  require(
    result['status'] == 'failed' &&
        result['progress']['rolledBack'] == true &&
        resolved(current) == selected,
    'fixture_update_rollback_failed',
  );
  await apiReady(environment());
  require(
    (await client.call('auth/session'))['data']['authenticated'] == true,
    'rollback_revoked_session',
  );
  stdout.writeln(
    'PASS: native panel updater, installer lock, prepared bundle, failed activation rollback and session preservation.',
  );
  unlink('$state/interruption-marker');
  await queue('0.8.0-dev.4');
  final end = DateTime.now().add(const Duration(seconds: 45));
  while (!exists('$state/interruption-marker') && DateTime.now().isBefore(end))
    await sleep();
  require(
    exists('$state/panel-update-intent.json') &&
        exists('$state/interruption-marker'),
    'fixture_interruption_stage_missing',
  );
  await run(['systemctl', 'kill', '--signal=KILL', 'sky-ui-update.service']);
  for (var n = 0; n < 100; n++) {
    final state = (await command([
      'systemctl',
      'show',
      'sky-ui-update.service',
      '--property=ActiveState',
      '--value',
    ])).stdout.toString().trim();
    if (!['active', 'activating', 'deactivating'].contains(state)) break;
    await sleep();
  }
  await run([
    'systemctl',
    'start',
    'sky-ui-update-recovery.service',
  ], timeout: const Duration(minutes: 2));
  await apiReady(environment());
  require(
    !exists('$state/panel-update-intent.json') && resolved(current) == selected,
    'fixture_interrupted_update_not_restored',
  );
  require(
    (await client.call('auth/session'))['data']['authenticated'] == true,
    'recovery_revoked_session',
  );
  stdout.writeln(
    'PASS: interrupted native update recovers the previous release and authenticated data.',
  );
}
