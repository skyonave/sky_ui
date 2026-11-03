import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sky_ui_ops/src/platform/host.dart';
import 'package:sky_ui_ops/src/features/backups/backups.dart';
import 'package:sky_ui_ops/src/shared/progress.dart';

void main() {
  group(
    'Native filesystem and database boundary',
    () {
      late String root;
      setUp(() {
        root = Directory.systemTemp.createTempSync('sky-ui-native-test-').path;
      });
      tearDown(() {
        if (exists(root)) Directory(root).deleteSync(recursive: true);
      });
      test('atomic replacement preserves old hardlink target', () async {
        File('$root/original').writeAsStringSync('private');
        await Process.run('ln', ['$root/original', '$root/destination']);
        host.atomic(
          '$root/destination',
          utf8.encode('new'),
          uid: host.uid(),
          gid: host.gid(),
        );
        expect(readText('$root/destination'), 'new');
        expect(File('$root/original').readAsStringSync(), 'private');
      });
      test('read rejects hardlinks', () async {
        File('$root/original').writeAsStringSync('private');
        await Process.run('ln', ['$root/original', '$root/hardlink']);
        expect(() => host.read('$root/hardlink'), throwsA(isA<OpsError>()));
      });
      test('read rejects symlink file', () {
        File('$root/original').writeAsStringSync('private');
        Link('$root/link').createSync('$root/original');
        expect(() => host.read('$root/link'), throwsA(isA<OpsError>()));
      });
      test('unlink removes directory symlink and preserves its target', () {
        Directory('$root/foreign').createSync();
        File('$root/foreign/sentinel').writeAsStringSync('preserve');
        Link('$root/current').createSync('$root/foreign');
        unlink('$root/current');
        expect(exists('$root/current'), isFalse);
        expect(File('$root/foreign/sentinel').readAsStringSync(), 'preserve');
      });
      test('read and write reject symlink parent', () {
        Directory('$root/real').createSync();
        File('$root/real/file').writeAsStringSync('private');
        Link('$root/alias').createSync('$root/real');
        expect(() => host.read('$root/alias/file'), throwsA(isA<OpsError>()));
        expect(
          () => host.atomic('$root/alias/new', utf8.encode('new')),
          throwsA(isA<OpsError>()),
        );
        expect(exists('$root/real/new'), isFalse);
      });
      test('read rejects FIFO without blocking', () async {
        await Process.run('mkfifo', ['$root/fifo']);
        expect(() => host.read('$root/fifo'), throwsA(isA<OpsError>()));
      });
      test('read enforces size and ownership', () {
        File('$root/data').writeAsStringSync('private');
        expect(
          () => host.read('$root/data', limit: 2),
          throwsA(isA<OpsError>()),
        );
        expect(
          () => host.read('$root/data', uid: host.uid() + 12345),
          throwsA(isA<OpsError>()),
        );
      });
      test('recursive delete unlinks symlink without following it', () {
        Directory('$root/outside').createSync();
        File('$root/outside/sentinel').writeAsStringSync('preserve');
        Directory('$root/tree').createSync();
        Link('$root/tree/escape').createSync('$root/outside');
        host.deleteTree('$root/tree');
        expect(File('$root/outside/sentinel').readAsStringSync(), 'preserve');
      });
      test('independent process cannot acquire held lock', () async {
        final lock = HostLock('$root/lock');
        try {
          await lock.acquire();
          final result = await Process.run('flock', [
            '-n',
            '$root/lock',
            'true',
          ]);
          expect(result.exitCode, isNot(0));
          lock.unlock();
          expect(
            (await Process.run('flock', ['-n', '$root/lock', 'true'])).exitCode,
            0,
          );
        } finally {
          lock.close();
        }
      }, skip: !Platform.isLinux ? 'Linux only' : false);
      test(
        'installer inherits the held lock and retains private diagnostics',
        () async {
          final result = <String, dynamic>{
            'id': 'a' * 32,
            'action': 'panel-update',
            'status': 'running',
          };
          final reporter = Reporter(
            result,
            '0.7.0-dev.4',
            'v0.8.0-dev.1',
            host.gid(),
            output: '$root/result.json',
          );
          final lock = HostLock('$root/install.lock');
          try {
            await lock.acquire();
            await expectLater(
              runInstaller(
                [
                  '/bin/bash',
                  '-c',
                  'flock -n 9 || exit 42; echo SKY_UI_STAGE=prepare; echo private-fixture-output; exit 23',
                ],
                reporter,
                installLock: lock,
              ),
              throwsA(
                isA<InstallerFailure>().having((e) => e.exitCode, 'exit', 23),
              ),
            );
          } finally {
            lock.close();
          }
          expect(reporter.progress['stage'], 'prepare');
          expect(jsonEncode(result), isNot(contains('private-fixture-output')));
          expect(
            readText('$root/logs/update-${'a' * 32}.log'),
            contains('private-fixture-output'),
          );
        },
      );
      test('installer exposes only allowlisted failure reasons', () async {
        for (final reason in [
          'native_binary_incompatible',
          'private-fixture-output',
        ]) {
          final reporter = Reporter(
            {'id': 'b' * 32, 'action': 'panel-update', 'status': 'running'},
            '0.8.0-dev.1',
            'v0.8.0-dev.2',
            host.gid(),
            output: '$root/result.json',
          );
          await expectLater(
            runInstaller([
              '/bin/bash',
              '-c',
              'echo SKY_UI_ERROR=$reason; exit 1',
            ], reporter),
            throwsA(
              isA<InstallerFailure>()
                  .having((e) => e.exitCode, 'exit', 1)
                  .having(
                    (e) => e.code,
                    'reason',
                    reason == 'native_binary_incompatible'
                        ? reason
                        : 'installer_failed',
                  ),
            ),
          );
          expect(
            jsonEncode(reporter.result),
            isNot(contains('private-fixture-output')),
          );
        }
      });
      test(
        'SQLite snapshot contains live WAL and clears only copied sessions',
        () async {
          final db = sqlite3.open('$root/live.sqlite');
          try {
            db.execute('PRAGMA journal_mode=WAL');
            db.execute('CREATE TABLE sessions(id TEXT)');
            db.execute("INSERT INTO sessions VALUES('fixture-session')");
            await databaseCopy(
              '$root/live.sqlite',
              '$root/backup.sqlite',
              sessions: false,
            );
            final copy = sqlite3.open('$root/backup.sqlite');
            try {
              expect(
                copy.select('SELECT count(*) FROM sessions').first.values.first,
                0,
              );
              expect(
                db.select('SELECT count(*) FROM sessions').first.values.first,
                1,
              );
            } finally {
              copy.close();
            }
          } finally {
            db.close();
          }
        },
      );
    },
    skip:
        !Platform.isLinux ||
            !Platform.environment.containsKey('SKY_UI_POSIX_LIBRARY')
        ? 'Run on Linux with the compiled POSIX library.'
        : false,
  );
}
