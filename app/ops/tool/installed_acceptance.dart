import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sky_ui_ops/src/platform/host.dart';
import 'package:sky_ui_ops/src/shared/archives.dart';
import 'package:sky_ui_ops/src/features/backups/backups.dart';
import 'package:sky_ui_ops/src/cli/commands.dart' as cli;

import 'installed_fleet.dart';
import 'installed_updates.dart';

// This harness deliberately exercises fixed production paths, only inside a
// disposable private-network systemd guest. Never run it against an owner host.
void isolated() {
  require(Platform.isLinux && host.uid() == 0, 'isolated_linux_root_required');
  require(
    File('/run/systemd/container').readAsStringSync().trim() ==
            'systemd-nspawn' &&
        Platform.localHostname == 'sky-ui-install-test' &&
        File('/unrelated-fixture').readAsStringSync() == 'preserve me',
    'isolated_fixture_required',
  );
  final original = Platform.environment['SKY_UI_TEST_PARENT_NET_NS'];
  require(
    original != null && Link('/proc/self/ns/net').targetSync() != original,
    'private_network_required',
  );
}

class Client {
  final http = HttpClient()..findProxy = ((_) => 'DIRECT');
  late final Map<String, String> headers = {
    'X-Sky-UI-Gateway': readText('$etc/gateway.secret', 256).trim(),
    'Origin': environment()['SKY_UI_WEB_ORIGIN']!,
  };
  Future<Map<String, dynamic>> call(
    String path, {
    String method = 'GET',
    Object? value,
    int expected = 200,
  }) async {
    final request = await http.openUrl(
      method,
      Uri.parse('http://127.0.0.1:39241/api/v1/$path'),
    );
    headers.forEach(request.headers.set);
    if (value != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(value));
    }
    final response = await request.close().timeout(const Duration(seconds: 40)),
        body = object(jsonDecode(await utf8.decoder.bind(response).join()));
    require(
      response.statusCode == expected,
      'fixture_http_${response.statusCode}_${body['error']?['code'] ?? 'unknown'}',
    );
    if (path == 'auth/login') {
      headers['Cookie'] = response.headers['set-cookie']!.first
          .split(';')
          .first;
      headers['X-Sky-UI-CSRF'] = body['data']['csrf'] as String;
    }
    return body;
  }

  Future<Map<String, dynamic>> panel() async =>
      object((await call('panel'))['data']);
}

Future<void> main(List<String> args) async {
  isolated();
  if (args.length == 1 && args.single == '--uninstall') {
    await cli.uninstall();
    return;
  }
  require(
    args.length == 2 || args.length == 3,
    'Pass the checked installer and prepared native bundle.',
  );
  var installer = args[0];
  final bundle = args[1], owner = await account('sky-ui');
  final panelOnly = args.length == 3 && args[2] == '--panel-updates';
  await apiReady(environment());
  final password = randomId(24);
  final hash = (await command([
    '$current/bin/caddy',
    'hash-password',
    '--algorithm',
    'bcrypt',
    '--bcrypt-cost',
    '4',
  ], input: '$password\n')).stdout.toString().trim();
  host.atomic(
    '$etc/owner.seed',
    utf8.encode('admin $hash\n'),
    mode: 0x180,
    uid: owner.uid,
    gid: owner.gid,
  );
  host.atomic(
    '$etc/Caddyfile',
    utf8.encode('# Offline fixture.\n'),
    mode: 0x1a0,
    gid: (await account('sky-ui-edge')).gid,
  );
  await run([
    '/usr/local/bin/skyui',
    'restart',
  ], timeout: const Duration(minutes: 2));
  await apiReady(environment());
  final client = Client();
  try {
    await client.call(
      'auth/login',
      method: 'POST',
      value: {'username': 'admin', 'password': password},
    );
    require(
      (await client.call('auth/session'))['data']['authenticated'] == true,
      'fixture_login_failed',
    );
    final engineList = (await client.call('cores'))['data'] as List;
    require(engineList.length == 4, 'fixture_engine_inventory');
    require(
      !Directory(resolved(current))
          .listSync(recursive: true, followLinks: false)
          .any(
            (e) =>
                e.path.endsWith('.py') ||
                e.path.endsWith('.dart') ||
                e.path.contains('/.dart_tool/'),
          ),
      'runtime_source_not_cleaned',
    );
    await run(['/usr/local/bin/skyui', 'status']);
    await run(['/usr/local/bin/skyui', 'logs', 'all', '-n', '20']);
    if (args.length == 3 && !panelOnly) await exerciseFleet(client, args[2]);
    final secretPaths = [
      '$etc/gateway.secret',
      '$etc/controller.secret',
      '$etc/owner.seed',
    ];
    final before = {
      for (final path in secretPaths) path: digest(host.read(path)),
    };
    final initialPanel = await client.panel();
    await command([
      '/usr/local/bin/skyui',
      'backup',
    ], timeout: const Duration(minutes: 3));
    await apiReady(environment());
    if (exists(downloadCache)) {
      require(
        !Directory(downloadCache)
            .listSync()
            .any((f) => f.path.endsWith('.zip') || f.path.endsWith('.tar.gz')),
        'successful_install_kept_downloads',
      );
    }
    final backups =
        Directory('$state/backups')
            .listSync()
            .whereType<File>()
            .where(
              (f) => RegExp(r'^[a-f0-9]{32}\.json$').hasMatch(basename(f.path)),
            )
            .toList()
          ..sort(
            (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
          );
    require(backups.isNotEmpty, 'backup_missing');
    final backupId = basename(backups.first.path).replaceFirst('.json', '');
    final manifest = unpackBackup(host.read('$state/backups/$backupId.tar.gz'))
        .manifest;
    require(manifest['purpose'] == 'manual', 'backup_purpose_invalid');
    final repeated = await command(
      ['bash', installer, '--bundle', bundle],
      check: false,
      timeout: const Duration(minutes: 10),
    );
    if (repeated.exitCode != 0) {
      File('/var/tmp/sky-ui-fixture-installer.log')
          .writeAsStringSync('${repeated.stdout}\n${repeated.stderr}');
      throw const OpsError('fixture_repeat_install_failed');
    }
    require(
      readText('${resolved(current)}/BUILD_MODE').trim() == 'native-v1' &&
          !repeated.stdout.toString().contains('Dart SDK') &&
          !Directory('${resolved(current)}/source').existsSync(),
      'repeat_install_not_native',
    );
    await apiReady(environment());
    require(
      (await client.call('auth/session'))['data']['authenticated'] == true,
      'reinstall_revoked_session',
    );
    require(
      before.entries.every((e) => digest(host.read(e.key)) == e.value),
      'reinstall_changed_secret',
    );
    require(
      jsonEncode((await client.panel())['connections']) ==
          jsonEncode(initialPanel['connections']),
      'reinstall_changed_records',
    );
    stdout.writeln(
      'PASS: native-only install, authenticated API, CLI, backup, repeated install and session preservation.',
    );
    await command(
      ['/usr/local/bin/skyui', 'restore', backupId],
      input: 'RESTORE\n',
      timeout: const Duration(minutes: 3),
    );
    await apiReady(environment());
    require(
      (await client.call('auth/session'))['data']['authenticated'] == false,
      'restore_did_not_revoke_session',
    );
    await client.call(
      'auth/login',
      method: 'POST',
      value: {'username': 'admin', 'password': password},
    );
    require(
      jsonEncode((await client.panel())['connections']) ==
          jsonEncode(initialPanel['connections']),
      'restore_changed_records',
    );
    stdout.writeln('PASS: backup restore and server-side session revocation.');
    if (args.length == 3 && !panelOnly) {
      require(
        ((await client.panel())['instanceReadiness'] as Map).values.every(
          (v) => v == true,
        ),
        'restored_fleet_not_ready',
      );
      await coreJob('remove', 'sing-box', args[2]);
      final removed = await client.panel();
      require(
        removed['coreAvailability']['sing-box'] == false &&
            removed['connections'].length == 4,
        'removed_engine_not_visible',
      );
      final recipient = object((removed['recipients'] as List).first);
      await client.call(
        'recipients/${recipient['id']}',
        method: 'PUT',
        value: {
          'revision': removed['revision'],
          'recipient': {...recipient, 'enabled': false},
        },
      );
      await coreJob('install', 'sing-box', args[2]);
      require(
        (await client.panel())['recipients'][0]['enabled'] == false,
        'reinstall_reenabled_recipient',
      );
      require(
        !await active('sky-ui-sing-box.service'),
        'reinstall_started_removed_engine',
      );
      stdout.writeln(
        'PASS: all-engine restore, visible removal, revocation and stopped reinstall.',
      );
      await exercisePanelUpdates(client);
    }
    if (panelOnly) {
      await exercisePanelUpdates(client);
      installer = '/source/install.sh';
    }
    // Probe passes, but activation fails. The public installer must restore the
    // old link and services without revoking the newly established session.
    await temporary('/var/tmp', 'sky-ui-failed-update-', (work) async {
      // Exercise activation failure using the installed native runtime.
      final selected = resolved(current), files = <String, Uint8List>{};
      for (final file in Directory(
        selected,
      ).listSync(recursive: true, followLinks: false)) {
        require(!isLink(file.path), 'fixture_runtime_link');
        if (file is File)
          files[file.path.substring(selected.length + 1)] = file
              .readAsBytesSync();
      }
      final version = readText('${resolved(current)}/VERSION', 128).trim();
      final brokenVersion = '$version.failure';
      files['VERSION'] = Uint8List.fromList(utf8.encode('$brokenVersion\n'));
      files['bin/sky-ui'] = Uint8List.fromList(
        utf8.encode(
          '#!/bin/sh\nif [ "\$1" = --version ]; then echo "Sky UI $brokenVersion"; else exit 23; fi\n',
        ),
      );
      final broken = packTar(files),
          name = basename(bundle),
          path = '$work/$name';
      File(path).writeAsBytesSync(broken);
      File('$path.sha256').writeAsStringSync('${digest(broken)}  $name\n');
      final original = resolved(current),
          result = await command(
            ['bash', installer, '--bundle', path],
            check: false,
            timeout: const Duration(minutes: 3),
          );
      require(
        result.exitCode != 0 && resolved(current) == original,
        'failed_install_not_rolled_back',
      );
      final cached = '$downloadCache/panel-${digest(broken)}.tar.gz';
      require(
        exists(cached) && digest(host.read(cached)) == digest(broken),
        'failed_install_download_not_retained',
      );
      await apiReady(environment());
      require(
        (await client.call('auth/session'))['data']['authenticated'] == true,
        'failed_install_revoked_session',
      );
    });
    stdout.writeln(
      'PASS: failed candidate activation restores the previous native release and session.',
    );
    // Fake older immutable releases test current/previous retention and active refs.
    final selected = resolved(current),
        old = '$releases/0.0.1-amd64',
        previous = '$releases/0.0.2-amd64';
    host.mkdir(old);
    host.mkdir(previous);
    atomicJson('$releases/retention.json', {
      'current': selected,
      'previous': previous,
    }, mode: 0x180);
    await run(['/usr/local/bin/skyui', 'cleanup']);
    require(
      !exists(old) &&
          exists(previous) &&
          exists('$state/backups/$backupId.tar.gz'),
      'retention_failed',
    );
    stdout.writeln(
      'PASS: current plus one previous release; manual backups remain.',
    );
    await command(
      ['/usr/local/bin/skyui', 'uninstall'],
      input: 'DELETE\n',
      timeout: const Duration(minutes: 3),
    );
    for (final path in [
      '/opt/sky-ui',
      etc,
      dataRoot,
      state,
      '/var/lib/sky-ui-amneziawg-network',
      '/usr/local/bin/skyui',
      downloadCache,
      '/etc/tmpfiles.d/sky-ui-install.conf',
    ])
      require(!exists(path), 'uninstall_incomplete');
    require(
      !exists('/etc/systemd/journald@sky-ui.conf') &&
          File('/unrelated-fixture').readAsStringSync() == 'preserve me',
      'uninstall_touched_foreign_data',
    );
    stdout.writeln(
      'PASS: full uninstall removes managed runtime/data and preserves the foreign sentinel.',
    );
  } finally {
    client.http.close(force: true);
  }
}
