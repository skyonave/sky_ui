import 'dart:io';

import 'package:test/test.dart';
import 'package:sky_ui_ops/src/platform/host.dart';
import 'package:sky_ui_ops/src/features/certificates/certificates.dart';

void main() {
  group(
    'Managed certificate publishing',
    () {
      late String root, source, destination;
      const name = 'fixture.example.test';
      setUp(() {
        root = Directory.systemTemp.createTempSync('sky-ui-cert-test-').path;
        source = '$root/source';
        destination = '$root/published';
        Directory('$source/acme-v02.api.letsencrypt.org-directory/$name')
            .createSync(recursive: true);
      });
      tearDown(() => Directory(root).deleteSync(recursive: true));
      Future<void> issue() async => run([
        'openssl',
        'req',
        '-x509',
        '-newkey',
        'ec',
        '-pkeyopt',
        'ec_paramgen_curve:P-256',
        '-nodes',
        '-days',
        '1',
        '-subj',
        '/CN=$name',
        '-addext',
        'subjectAltName=DNS:$name',
        '-keyout',
        '$source/acme-v02.api.letsencrypt.org-directory/$name/$name.key',
        '-out',
        '$source/acme-v02.api.letsencrypt.org-directory/$name/$name.crt',
      ]);
      Future<Map<String, dynamic>> publish() => syncCertificates(
        source: source,
        destination: destination,
        hosts: [name],
        primary: name,
        sourceUid: host.uid(),
        gid: host.gid(),
      );
      test(
        'publishes validated pair, rotates and retains last valid pair',
        () async {
          await issue();
          final first = await publish();
          expect(first['panel']['host'], name);
          final before = File('$destination/panel/private.key')
              .statSync()
              .modified;
          expect(await publish(), first);
          expect(
            File('$destination/panel/private.key').statSync().modified,
            before,
          );
          File('$source/acme-v02.api.letsencrypt.org-directory/$name/$name.key')
              .writeAsStringSync('invalid fixture key');
          expect(await publish(), first);
          await issue();
          final second = await publish();
          expect(
            second['panel']['fingerprint'],
            isNot(first['panel']['fingerprint']),
          );
          expect(second['panel'], second[name]);
          final fd = host.open('$destination/panel/private.key');
          try {
            expect(host.metadata(fd)[0] & 0x1ff, 0x1a0);
          } finally {
            host.close(fd);
          }
        },
      );
      test(
        'foreign source owner is rejected without publishing keys',
        () async {
          await issue();
          final found = await syncCertificates(
            source: source,
            destination: destination,
            hosts: [name],
            primary: name,
            sourceUid: host.uid() + 12345,
            gid: host.gid(),
          );
          expect(found, isEmpty);
          expect(File('$destination/panel/private.key').existsSync(), isFalse);
        },
      );
      test('certificate hostname mismatch is rejected', () async {
        await issue();
        final prefix =
            '$source/acme-v02.api.letsencrypt.org-directory/other.example.test';
        Directory(prefix).createSync();
        File('$source/acme-v02.api.letsencrypt.org-directory/$name/$name.crt')
            .copySync('$prefix/other.example.test.crt');
        File('$source/acme-v02.api.letsencrypt.org-directory/$name/$name.key')
            .copySync('$prefix/other.example.test.key');
        expect(
          await syncCertificates(
            source: source,
            destination: destination,
            hosts: ['other.example.test'],
            primary: 'other.example.test',
            sourceUid: host.uid(),
            gid: host.gid(),
          ),
          isEmpty,
        );
      });
    },
    skip:
        !Platform.isLinux ||
            !Platform.environment.containsKey('SKY_UI_POSIX_LIBRARY')
        ? 'Linux native fixture required.'
        : false,
  );
}
