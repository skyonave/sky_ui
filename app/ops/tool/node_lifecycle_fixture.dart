import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sky_ui_ops/src/features/servers/node_worker.dart';
import 'package:sky_ui_ops/src/platform/host.dart';

/// Runs only in the explicitly prepared disposable systemd acceptance guest.
Future<void> main(List<String> args) async {
  require(
    args.length == 1 && File('/sky-ui-debian-compat').existsSync(),
    'fixture_only',
  );
  final lock = HostLock('/run/lock/sky-ui-node.lock');
  await lock.acquire();
  try {
    final fixture = args.single;
    final user = await account('sky-ui-relay');
    for (final id in nodeEngines) {
      final engine = NodeEngine(id);
      await engine.initialize();
      final binary = File(engine.binary).readAsBytesSync();
      final config = File('$fixture/configurations/$id.json').readAsBytesSync();
      host.atomic(engine.configuration, config, gid: user.gid, mode: 0x1a0);
      Map<String, Uint8List> files(String version, {bool broken = false}) => {
        id: broken
            ? Uint8List.fromList(
                utf8.encode(
                  '#!/bin/sh\ncase "\$1" in -t|check) exit 0;; run) [ "\$2" != -test ] || exit 0;; esac\nexit 1\n',
                ),
              )
            : binary,
        'artifact.json': Uint8List.fromList(
          utf8.encode(jsonEncode({'version': version})),
        ),
      };
      stdout.writeln(
        'TEST $id retained configuration installation and restart',
      );
      await engine.activateVerifiedArtifact('v1.0.1', files('v1.0.1'));
      require(await active(engine.unit), 'fixture_start_failed');
      await engine.remove();
      require(
        !engine.installed && !await active(engine.unit),
        'fixture_remove_failed',
      );
      require(
        digest(host.read(engine.configuration)) == digest(config),
        'fixture_config_lost',
      );
      await engine.activateVerifiedArtifact('v1.0.1', files('v1.0.1'));
      require(await active(engine.unit), 'fixture_reinstall_stopped');
      final current = resolved('${engine.slots}/current');
      var failed = false;
      try {
        await engine.activateVerifiedArtifact(
          'v9.9.9',
          files('v9.9.9', broken: true),
          update: true,
        );
      } on OpsError {
        failed = true;
      }
      require(
        failed &&
            resolved('${engine.slots}/current') == current &&
            await active(engine.unit),
        'fixture_activation_rollback_failed',
      );
      stdout.writeln('TEST $id failed update restored running binary');
      // Simulate a process death after publishing the new link, before activation.
      final interrupted = '${engine.slots}/v9.9.8-0123456789abcdef';
      host.mkdir(interrupted, mode: 0x1ed);
      host.atomic(
        '$interrupted/$id',
        files('v9.9.8', broken: true)[id]!,
        mode: 0x1ed,
      );
      atomicJson('${engine.slots}/activation.json', {
        'previous': current,
        'candidate': interrupted,
        'running': true,
        'autoStart': false,
      }, mode: 0x180);
      switchLink('${engine.slots}/current', interrupted);
      await run(['systemctl', 'stop', engine.unit]);
      await NodeEngine(id).initialize();
      require(
        resolved('${engine.slots}/current') == current &&
            await active(engine.unit) &&
            !exists('${engine.slots}/activation.json'),
        'fixture_interrupted_recovery_failed',
      );
      stdout.writeln(
        'TEST $id interrupted activation recovered on next command',
      );
      await engine.activateVerifiedArtifact(
        'v1.0.2',
        files('v1.0.2'),
        update: true,
      );
      await engine.activateVerifiedArtifact(
        'v1.0.3',
        files('v1.0.3'),
        update: true,
      );
      require(
        Directory(engine.slots)
                .listSync(followLinks: false)
                .whereType<Directory>()
                .length ==
            2,
        'fixture_retention_failed',
      );
      await run(['systemctl', 'disable', '--now', engine.unit]);
      await engine.activateVerifiedArtifact(
        'v1.0.4',
        files('v1.0.4'),
        update: true,
      );
      require(!await active(engine.unit), 'fixture_manual_stop_lost');
      host.atomic(
        engine.configuration,
        utf8.encode(nodeBaseline(id)),
        gid: user.gid,
        mode: 0x1a0,
      );
    }
    stdout.writeln(
      'PASS: reinstall auto-start, update rollback, one rollback slot, manually stopped update preserved.',
    );
  } finally {
    lock.close();
  }
}
