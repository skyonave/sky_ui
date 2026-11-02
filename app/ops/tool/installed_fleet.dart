import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_ops/src/host.dart';
import 'package:sky_ui_ops/src/backups.dart';
import 'package:sky_ui_ops/src/maintenance.dart' show waitCleanup;

import 'installed_acceptance.dart' show Client, isolated;

Future<void> coreJob(String action, String core, String fixture) async {
  isolated();
  final owner = await account('sky-ui');
  final receipt = object(
    jsonDecode(File('$fixture/$core.artifact.json').readAsStringSync()),
  );
  final id = randomId();
  atomicJson(
    '$state/inbox/request.json',
    {
      'id': id,
      'action': action,
      'core': core,
      if (action != 'remove') 'tag': receipt['version'],
    },
    mode: 0x180,
    uid: owner.uid,
    gid: owner.gid,
  );
  await run([
    'systemctl',
    'start',
    'sky-ui-maintenance.service',
  ], timeout: const Duration(minutes: 3));
  final result = readJson('$state/result.json');
  require(
    result['id'] == id && result['status'] == 'completed',
    'fixture_core_job_failed_${result['error']}',
  );
  await apiReady(environment());
  await waitCleanup();
}

Future<void> exerciseFleet(Client client, String fixture) async {
  isolated();
  // Write into the guest's runtime mount, not its hidden on-disk /run directory.
  for (final entry in {'maintenance': '', 'update': ' --panel'}.entries) {
    final directory = '/run/systemd/system/sky-ui-${entry.key}.service.d';
    Directory(directory).createSync(recursive: true);
    File('$directory/fixture.conf').writeAsStringSync(
      '[Service]\nExecStart=\nExecStart=/source/fixture-worker/bundle/bin/fixture_worker $fixture${entry.value}\nEnvironment=SKY_UI_POSIX_LIBRARY=/source/libsky_posix.so\nEnvironment=SKY_UI_TEST_PARENT_NET_NS=${Platform.environment['SKY_UI_TEST_PARENT_NET_NS']}\n',
    );
  }
  await run(['systemctl', 'daemon-reload']);
  for (final core in engineIds) await coreJob('install', core, fixture);
  Future<Map<String, dynamic>> add(
    String core,
    String protocol,
    int port,
    Map<String, String> settings,
  ) async {
    final response = await client.call(
      'connections',
      method: 'POST',
      value: {
        'revision': (await client.panel())['revision'],
        'connection': {
          'id': '',
          'name': core,
          'coreId': core,
          'instanceId': core == 'mihomo' ? 'primary' : core,
          'protocolId': protocol,
          'port': port,
          'enabled': true,
          'settings': settings,
        },
      },
    );
    return object((response['data']['connections'] as List).last);
  }

  final cert = File('$fixture/cert.pem').readAsStringSync(),
      key = File('$fixture/key.pem').readAsStringSync();
  final connections = [
    await add('xray', 'vless', 35001, {
      'listen': '127.0.0.1',
      'serverName': 'www.kernel.org',
    }),
    await add('sing-box', 'hysteria2', 35002, {
      'listen': '127.0.0.1',
      'serverName': 'localhost',
      'certificateSource': 'custom',
      'tlsCertificate': cert,
      'tlsPrivateKey': key,
      'obfs': 'salamander',
    }),
    await add('amneziawg', 'amneziawg', 35003, {}),
    await add('mihomo', 'mieru', 35004, {'listen': '127.0.0.1'}),
  ];
  await client.call(
    'recipients',
    method: 'POST',
    value: {
      'revision': (await client.panel())['revision'],
      'recipient': {
        'id': '',
        'name': 'all engines',
        'enabled': true,
        'connectionIds': connections.map((v) => v['id']).toList(),
      },
    },
  );
  for (final core in engineIds)
    await client.call(
      'cores/${core == 'mihomo' ? 'primary' : core}/actions/start',
      method: 'POST',
      value: {},
    );
  require(
    ((await client.panel())['instanceReadiness'] as Map).values.every(
      (v) => v == true,
    ),
    'fleet_not_ready',
  );
  Future<Map<String, String>> pids() async => {
    for (final core in engineIds)
      core: (await run([
        'systemctl',
        'show',
        'sky-ui-$core.service',
        '--property=MainPID',
        '--value',
      ])).trim(),
  };
  final beforeEdit = await pids();
  final edited = {...connections[1], 'port': 35012};
  await client.call(
    'connections/${edited['id']}',
    method: 'PUT',
    value: {
      'revision': (await client.panel())['revision'],
      'connection': edited,
    },
  );
  final afterEdit = await pids();
  require(
    engineIds.every(
      (c) => (beforeEdit[c] != afterEdit[c]) == (c == 'sing-box'),
    ),
    'unrelated_engine_restarted',
  );
  for (final core in engineIds) {
    final before = await pids();
    await coreJob('update', core, fixture);
    final after = await pids();
    require(
      engineIds.every((c) => (before[c] != after[c]) == (c == core)),
      'unrelated_engine_restarted',
    );
    require(
      ((await client.panel())['instanceReadiness'] as Map).values.every(
        (v) => v == true,
      ),
      'fleet_update_not_ready',
    );
  }
  stdout.writeln(
    'PASS: four native engines, concurrent readiness, grants and scoped configuration/update.',
  );
}
