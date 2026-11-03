import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:sky_ui_ops/src/platform/host.dart';
import 'package:sky_ui_ops/src/features/storage/retention.dart';

void main() {
  group(
    'Managed retention boundaries',
    () {
      late String root, versions;
      late Retention retention;
      setUp(() {
        root = Directory.systemTemp
            .createTempSync('sky-ui-retention-test-')
            .path;
        versions = '$root/releases';
        Directory(versions).createSync();
        retention = Retention(
          releaseRoot: versions,
          proc: '$root/proc',
          temporaryRoot: '$root/tmp',
          downloadRoot: '$root/downloads',
        );
      });
      tearDown(() => Directory(root).deleteSync(recursive: true));
      String slot(String version) {
        final path = '$versions/$version-amd64';
        Directory(path).createSync();
        File('$path/marker').writeAsStringSync(version);
        return path;
      }

      test(
        'keep current, actual predecessor and a still-running older release',
        () {
          final first = slot('0.1.0'),
              previous = slot('0.2.0'),
              selected = slot('0.3.0');
          retention.record(versions, selected, previous);
          retention.pruneVersions(versions, selected, releasePattern, [
            '$first/bin/sky-ui',
          ], panel: true);
          expect(exists(first), isTrue);
          retention.pruneVersions(
            versions,
            selected,
            releasePattern,
            [],
            panel: true,
          );
          expect(exists(first), isFalse);
          expect(exists(previous) && exists(selected), isTrue);
        },
      );
      test('repeat installation does not replace predecessor with current', () {
        final previous = slot('0.2.0'), selected = slot('0.3.0');
        retention.record(versions, selected, previous);
        retention.record(versions, selected, selected);
        expect(readJson('$versions/retention.json')['previous'], previous);
      });
      test('forged history cannot delete or adopt a foreign directory', () {
        final selected = slot('0.3.0');
        Directory('$root/foreign').createSync();
        File('$root/foreign/sentinel').writeAsStringSync('preserve');
        atomicJson('$versions/retention.json', {
          'current': selected,
          'previous': '$root/foreign',
        }, mode: 0x180);
        expect(
          () => retention.pruneVersions(
            versions,
            selected,
            releasePattern,
            [],
            panel: true,
          ),
          throwsA(isA<OpsError>()),
        );
        expect(File('$root/foreign/sentinel').readAsStringSync(), 'preserve');
      });
      test(
        'version-shaped symlink never causes recursive foreign deletion',
        () {
          final selected = slot('0.3.0');
          Directory('$root/foreign').createSync();
          File('$root/foreign/sentinel').writeAsStringSync('preserve');
          Link('$versions/0.1.0-amd64').createSync('$root/foreign');
          retention.record(versions, selected, null);
          retention.pruneVersions(
            versions,
            selected,
            releasePattern,
            [],
            panel: true,
          );
          expect(File('$root/foreign/sentinel').readAsStringSync(), 'preserve');
        },
      );
      test(
        'process reference scan tolerates unrelated invalid UTF-8 arguments',
        () {
          Directory('$root/proc/123/fd').createSync(recursive: true);
          Link('$root/proc/123/exe')
              .createSync('$versions/0.1.0-amd64/bin/sky-ui');
          Link('$root/proc/123/cwd').createSync(root);
          File('$root/proc/123/cmdline').writeAsBytesSync([
            255,
            0,
            ...utf8.encode('$versions/0.1.0-amd64'),
            0,
          ]);
          File('$root/proc/123/maps').writeAsStringSync(
            '0 0 0 0 0 $versions/0.1.0-amd64/lib/libsqlite3.so\n',
          );
          expect(retention.references(), contains('$versions/0.1.0-amd64'));
        },
      );
      test(
        'global temporary cleanup rejects foreign-owned lookalikes',
        () async {
          Directory('$root/foreign').createSync();
          await Process.run('chown', ['65534:65534', '$root/foreign']);
          expect(rootOwnedDirectory('$root/foreign'), isFalse);
        },
      );
      test('retry downloads keep one recent archive of each kind', () {
        host.mkdir('$root/downloads', mode: 0x1c0);
        host.atomic(
          '$root/downloads/managed-by-sky-ui',
          utf8.encode(downloadCacheMarker),
          mode: 0x180,
        );
        final now = DateTime.now();
        String cache(String kind, String character, int age) {
          final suffix = kind == 'dart' ? 'zip' : 'tar.gz';
          final path = '$root/downloads/$kind-${character * 64}.$suffix';
          host.atomic(path, [1], mode: 0x180);
          File(path).setLastModifiedSync(now.subtract(Duration(hours: age)));
          return path;
        }

        final newest = cache('dart', 'a', 1),
            old = cache('dart', 'b', 2),
            expired = cache('panel', 'c', 25);
        retention.pruneDownloads(now);
        expect(exists(newest), isTrue);
        expect(exists(old) || exists(expired), isFalse);
      });
      test('retry cache refuses an unmanaged directory', () {
        host.mkdir('$root/downloads', mode: 0x1c0);
        host.atomic('$root/downloads/foreign', [1], mode: 0x180);
        expect(
          () => retention.pruneDownloads(DateTime.now()),
          throwsA(isA<OpsError>()),
        );
        expect(exists('$root/downloads/foreign'), isTrue);
      });
    },
    skip:
        !Platform.isLinux ||
            !Platform.environment.containsKey('SKY_UI_POSIX_LIBRARY')
        ? 'Linux native root fixture required.'
        : false,
  );
}
