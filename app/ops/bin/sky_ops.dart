import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:sky_ui_ops/src/host.dart';
import 'package:sky_ui_ops/src/cli.dart';
import 'package:sky_ui_ops/src/releases.dart';
import 'package:sky_ui_ops/src/engines.dart';
import 'package:sky_ui_ops/src/amnezia.dart';
import 'package:sky_ui_ops/src/backups.dart';
import 'package:sky_ui_ops/src/certificates.dart';
import 'package:sky_ui_ops/src/storage.dart';
import 'package:sky_ui_ops/src/maintenance.dart';
import 'package:sky_ui_ops/src/panel_update.dart';

Future<void> main(List<String> args) async {
  try {
    if (args.isEmpty || args.first == 'cli') {
      await cliMain(args.isEmpty ? [] : args.sublist(1));
      return;
    }
    if (args.first == '--self-test') {
      final temp = Directory.systemTemp.createTempSync('sky-ui-selftest-').path;
      try {
        host.atomic('$temp/probe', utf8.encode('ok'), uid: host.uid());
        require(readText('$temp/probe') == 'ok', 'native_probe_failed');
        await databaseCopyProbe(temp);
        stdout.writeln('Sky UI native tools ready.');
      } finally {
        host.deleteTree(temp);
      }
      return;
    }
    if (args.first == 'releases') {
      require(args.length >= 6 && args[1] == 'check', 'request_invalid');
      String option(String key) {
        final i = args.indexOf(key);
        require(i >= 0 && i + 1 < args.length, 'request_invalid');
        return args[i + 1];
      }

      stdout.writeln(
        jsonEncode(
          await discover(
            option('--version'),
            option('--platform'),
            tag: args.contains('--tag') ? option('--tag') : null,
          ),
        ),
      );
      return;
    }
    if (args.length == 3 && args[0] == 'amnezia' && args[1] == 'check') {
      loadAwg(args[2]);
      return;
    }
    require(host.uid() == 0, 'root_required');
    host.umask(0x3f);
    switch (args.first) {
      case 'maintenance':
        await maintenanceMain(args.sublist(1));
      case 'panel-update':
        await panelUpdateMain(args.sublist(1));
      case 'certificates-sync':
        await syncCertificates();
      case 'amnezia':
        require(args.length >= 2, 'request_invalid');
        if (args[1] == 'check' && args.length == 3)
          loadAwg(args[2]);
        else if (args[1] == 'run' && args.length == 4)
          await runAwg(args[2], args[3]);
        else if (args[1] == 'cleanup' && args.length == 2)
          await cleanupAwgTable();
        else
          throw const OpsError('request_invalid');
      case 'database-copy':
        require(args.length == 3, 'request_invalid');
        await databaseCopy(args[1], args[2]);
      case 'core-bootstrap':
        require(args.length >= 2, 'request_invalid');
        String option(String key) {
          final i = args.indexOf(key);
          require(i >= 0 && i + 1 < args.length, 'request_invalid');
          return args[i + 1];
        }
        if (args[1] == 'prepare')
          stdout.writeln(
            await prepareMihomo(
                  option('--panel-version'),
                  option('--platform'),
                  option('--output'),
                ) ??
                '-',
          );
        else if (args[1] == 'validate')
          await validateMihomo(
            option('--binary'),
            option('--configuration'),
            option('--directory'),
          );
        else if (args[1] == 'activate')
          stdout.writeln(activateMihomo(option('--prepared')));
        else
          throw const OpsError('request_invalid');
      case 'storage':
        host.trusted('$etc/managed-by-sky-ui');
        if (args.length >= 2 && args[1] == '--record-panel') {
          Retention().recordPanel(
            args.length > 2 && args[2].isNotEmpty ? args[2] : null,
          );
          return;
        }
        final install = HostLock('/run/lock/sky-ui-install.lock'),
            worker = HostLock('$state/worker.lock');
        try {
          await install.acquire(timeout: Duration.zero);
          await worker.acquire(timeout: Duration.zero);
          atomicJson('$state/cleanup-intent.json', {}, mode: 0x180);
          try {
            stdout.writeln(jsonEncode(Retention().clean()));
          } finally {
            unlink('$state/cleanup-intent.json');
          }
        } on OpsError catch (e) {
          if (e.code != 'maintenance_busy') rethrow;
          stdout.writeln('{"skipped":"busy"}');
        } finally {
          worker.close();
          install.close();
        }
      default:
        throw const OpsError('request_invalid');
    }
  } on Object catch (error, trace) {
    stderr.writeln(
      'Sky UI: ${error is OpsError ? error.code : 'operation_failed'}',
    );
    if (error is CommandFailure) {
      stderr.writeln('${error.tool}: exit ${error.exitCode}');
      if (error.diagnostic != null)
        stderr.writeln('Details: ${error.diagnostic}');
    }
    // Keep unexpected failures diagnosable without printing values or arguments.
    if (error is! OpsError) stderr.writeln('${error.runtimeType}\n$trace');
    exitCode = 1;
  }
}

Future<void> databaseCopyProbe(String directory) async {
  // Exercise the packaged SQLite asset without touching installation databases.
  final path = '$directory/probe.sqlite';
  final db = sqlite3.open(path);
  db.execute('CREATE TABLE probe (id INTEGER PRIMARY KEY)');
  db.close();
  await databaseCopy(path, '$directory/copied.sqlite');
}
