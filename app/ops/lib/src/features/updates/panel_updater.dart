import 'dart:convert';
import 'dart:io';

import '../../platform/host.dart';
import '../../shared/archives.dart';
import '../../shared/artifacts.dart';
import '../../shared/progress.dart';
import '../backups/backups.dart';
import '../maintenance/request.dart';
import 'release_catalog.dart';

Future<Map<String, dynamic>> runtime(String path) async {
  final env = environment(),
      secret = readText(env['SKY_UI_GATEWAY_SECRET_FILE']!, 256).trim();
  return object(
    jsonDecode(
      utf8.decode(
        await httpBytes(
          'http://127.0.0.1:${env['SKY_UI_PORT']}$path',
          1024 * 1024,
          headers: {
            'X-Sky-UI-Gateway': secret,
            'Origin': env['SKY_UI_WEB_ORIGIN']!,
          },
          official: false,
          timeout: const Duration(seconds: 5),
        ),
      ),
    ),
  );
}

String previousRelease(String path) {
  require(
    parent(path) == releases &&
        parseVersion(
              basename(path).replaceFirst(RegExp(r'-(amd64|arm64)$'), ''),
            ) !=
            null,
    'unsafe_file',
  );
  host.trusted(path, directory: true);
  return path;
}

Future<void> rollbackPanel(
  Map<String, dynamic> intent,
  int gid, {
  bool start = true,
}) async {
  final previous = previousRelease(intent['previous'] as String),
      files = unpackBackup(
        host.read('$state/panel-update-backup.tar.gz'),
        complete: false,
      ).files;
  await run([
    'systemctl',
    'stop',
    'sky-ui-edge.service',
    'sky-ui.service',
    'sky-ui-certificates.timer',
    'sky-ui-certificates.service',
  ]);
  switchLink(current, previous);
  await applyFiles(files, gid);
  for (final unit in allUnits) {
    final source = '$previous/deploy/systemd/$unit',
        target = '/etc/systemd/system/$unit';
    if (exists(source)) {
      host.trusted(source);
      host.atomic(target, host.read(source), mode: 0x1a4);
    } else {
      if (unit.startsWith('sky-ui-cleanup.'))
        await command(['systemctl', 'disable', '--now', unit], check: false);
      unlink(target);
    }
  }
  const polkit = 'deploy/polkit/49-sky-ui.rules';
  host.trusted('$previous/$polkit');
  host.atomic(
    '/etc/polkit-1/rules.d/49-sky-ui.rules',
    host.read('$previous/$polkit'),
    mode: 0x1a4,
  );
  for (final name in ['skyui', 'sky-ui']) {
    host.trusted('$previous/deploy/$name');
    host.atomic(
      '/usr/local/bin/$name',
      host.read('$previous/deploy/$name'),
      mode: 0x1ed,
    );
  }
  await run(['systemctl', 'daemon-reload']);
  if (start) {
    for (final entry in {
      'sky-ui.service': 'api',
      'sky-ui-edge.service': 'edge',
      'sky-ui-certificates.timer': 'timer',
    }.entries)
      if (intent[entry.value] == true) {
        await command(['systemctl', 'reset-failed', entry.key], check: false);
        await run(['systemctl', 'start', entry.key]);
      }
    if (intent['api'] == true) await apiReady(environment());
  }
  unlink('$state/panel-update-intent.json');
  unlink('$state/panel-update-backup.tar.gz');
}

Future<void> recoverPanel(int gid, {bool start = false}) async {
  if (!exists('$state/panel-update-intent.json')) return;
  final status = (await run([
    'systemctl',
    'show',
    'sky-ui-update.service',
    '--property=ActiveState',
    '--value',
  ])).trim();
  if (['active', 'activating', 'deactivating'].contains(status)) return;
  final intent = readJson('$state/panel-update-intent.json', 4096);
  require(
    intent['id'] is String &&
        identityPattern.hasMatch(intent['id']) &&
        parseVersion(intent['tag']) != null &&
        ['api', 'edge', 'timer'].every((k) => intent[k] is bool),
    'request_invalid',
  );
  await rollbackPanel(intent, gid, start: start);
  atomicJson('$state/result.json', {
    'id': intent['id'],
    'action': 'panel-update',
    'status': 'failed',
    'error': 'panel_update_rolled_back',
  }, gid: gid);
}

Future<Map<String, dynamic>> updatePanel(
  Map<String, dynamic> job,
  int gid,
  HostLock worker,
  HostLock install,
  Reporter reporter, {
  Fetch? fetch,
}) async {
  final version = panelVersion(),
      platform = targetPlatform(),
      selected = await candidate(
        version,
        platform,
        requested: job['tag'] as String,
        fetch: fetch,
      );
  require(selected != null, 'panel_update_unavailable');
  return temporary('$state/work', 'panel-update-', (stage) async {
    reporter.stage('download');
    await prepareRelease(
      selected!,
      platform,
      stage,
      fetch: fetch,
      onProgress: reporter.transfer,
      onVerify: () => reporter.stage('verify'),
    );
    // Compile before stopping the API. A build failure leaves the running release intact.
    final built = '$stage/compiled';
    host.mkdir(built, mode: 0x1c0);
    reporter.stage('prepare');
    await runInstaller(
      [
        'bash',
        '$stage/install.sh',
        '--bundle',
        '$stage/sky-ui-$platform.tar.gz',
        '--prepare-only',
        built,
      ],
      reporter,
      installLock: install,
    );
    final intent = <String, dynamic>{
      'id': job['id'],
      'tag': job['tag'],
      'previous': previousRelease(resolved(current)),
      'api': await active('sky-ui.service'),
      'edge': await active('sky-ui-edge.service'),
      'timer': await active('sky-ui-certificates.timer'),
    };
    final configured = intent['api'] == true
        ? (await runtime('/api/v1/auth/session'))['data']['configured']
        : null;
    reporter.stage('backup');
    try {
      await run([
        'systemctl',
        'stop',
        'sky-ui-certificates.timer',
        'sky-ui-certificates.service',
        'sky-ui-edge.service',
        'sky-ui.service',
      ]);
      assertConfigurationSettled();
      final packed = packBackup(await snapshotFiles(sessions: true), {
        'version': version,
        'purpose': 'panel-update',
      });
      host.atomic(
        '$state/panel-update-backup.tar.gz',
        packed.bytes,
        mode: 0x180,
      );
      atomicJson('$state/panel-update-intent.json', intent, mode: 0x180);
      worker.unlock();
      reporter.stage('install');
      await runInstaller(
        [
          'bash',
          '$stage/install.sh',
          '--bundle',
          '$built/sky-ui-$platform.tar.gz',
        ],
        reporter,
        installLock: install,
        extraEnvironment: {'SKY_UI_DEFER_ROLLBACK_START': '1'},
      );
      await worker.acquire();
      reporter.stage('health');
      await apiReady(environment());
      require(
        (await runtime('/api/v1/health'))['version'] ==
            (job['tag'] as String).substring(1),
        'panel_version_mismatch',
      );
      if (configured != null)
        require(
          (await runtime('/api/v1/auth/session'))['data']['configured'] ==
              configured,
          'owner_state_mismatch',
        );
      if (intent['edge'] == true)
        await run(['systemctl', 'start', 'sky-ui-edge.service']);
      if (intent['api'] == false)
        await run(['systemctl', 'stop', 'sky-ui.service']);
      if (intent['timer'] == false)
        await run(['systemctl', 'stop', 'sky-ui-certificates.timer']);
      unlink('$state/panel-update-intent.json');
      unlink('$state/panel-update-backup.tar.gz');
      reporter.progress['finishedAt'] = now();
      reporter.stage('complete');
      return {'version': (job['tag'] as String).substring(1)};
    } on Object catch (error) {
      final failed = reporter.progress['stage'];
      reporter.stage('rollback', {'failedStage': failed});
      await worker.acquire();
      try {
        if (exists('$state/panel-update-intent.json'))
          await rollbackPanel(intent, gid);
        else
          for (final entry in {
            'sky-ui.service': 'api',
            'sky-ui-edge.service': 'edge',
            'sky-ui-certificates.timer': 'timer',
          }.entries)
            if (intent[entry.value] == true)
              await run(['systemctl', 'start', entry.key]);
      } on Object {
        reporter.failed('rollback_failed', {
          'rolledBack': false,
          'failedStage': failed,
        });
        rethrow;
      }
      reporter.failed(error.toString(), {
        'rolledBack': true,
        'failedStage': failed,
        if (error is InstallerFailure) ...{
          'exitCode': error.exitCode,
          'command': 'install.sh',
        },
      });
      throw const OpsError('panel_update_rolled_back');
    }
  });
}

Future<void> panelUpdateMain(List<String> args, {Fetch? fetch}) async {
  require(host.uid() == 0, 'root_required');
  host.umask(0x3f);
  host.trusted('$etc/managed-by-sky-ui');
  final owner = await account('sky-ui');
  final install = HostLock('/run/lock/sky-ui-install.lock'),
      worker = HostLock('$state/worker.lock');
  try {
    await install.acquire();
    await worker.acquire();
    if (args.length == 1 && args.first == '--recover') {
      await recoverPanel(owner.gid, start: true);
      return;
    }
    require(
      !intentNames.any((n) => exists('$state/$n')),
      'maintenance_recovery_required',
    );
    final job = consumeRequest(owner.uid, remove: false);
    require(job['action'] == 'panel-update', 'request_invalid');
    final result = <String, dynamic>{
          'id': job['id'],
          'action': 'panel-update',
          'status': 'running',
        },
        reporter = Reporter(
          result,
          panelVersion(),
          job['tag'] as String,
          owner.gid,
        );
    atomicJson('$state/result.json', result, gid: owner.gid);
    unlink('$state/inbox/request.json');
    try {
      result['data'] = await updatePanel(
        job,
        owner.gid,
        worker,
        install,
        reporter,
        fetch: fetch,
      );
      result['status'] = 'completed';
    } on Object catch (error, trace) {
      if (error is! OpsError) stderr.writeln('${error.runtimeType}\n$trace');
      final code = error is OpsError ? error.code : 'panel_update_failed';
      result.addAll({'status': 'failed', 'error': code});
      if (!reporter.progress.containsKey('finishedAt'))
        reporter.failed(code, {
          'failedStage': reporter.progress['stage'],
          'rolledBack': false,
          if (error is InstallerFailure) ...{
            'exitCode': error.exitCode,
            'command': 'install.sh',
          },
        });
    } finally {
      atomicJson('$state/result.json', result, gid: owner.gid);
    }
    require(
      !exists('$state/panel-update-intent.json'),
      'panel_update_recovery_required',
    );
  } finally {
    worker.close();
    install.close();
  }
}
