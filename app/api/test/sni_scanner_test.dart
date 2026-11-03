import 'dart:io';
import 'package:sky_ui_api/src/sni_scanner.dart';
import 'package:test/test.dart';

void main() {
  test(
    'neighbor discovery stays in one public /24 and has a fixed upper bound',
    () {
      for (final host in [1, 63, 254]) {
        final values = neighboringSniAddresses(
          InternetAddress('177.177.212.$host'),
        );
        expect(values, hasLength(64));
        expect(values.toSet(), hasLength(64));
        expect(values, isNot(contains('177.177.212.$host')));
        expect(values.every((v) => v.startsWith('177.177.212.')), isTrue);
        expect(values, isNot(contains('177.177.212.0')));
        expect(values, isNot(contains('177.177.212.255')));
      }
    },
  );
  test(
    'neighbor discovery rejects local, metadata, CGNAT and multicast targets',
    () {
      for (final host in [
        '127.0.0.1',
        '10.0.0.1',
        '169.254.169.254',
        '192.168.0.1',
        '172.16.1.1',
        '100.64.0.1',
        '224.0.0.1',
        '::1',
      ]) {
        expect(
          () => neighboringSniAddresses(InternetAddress(host)),
          throwsA(anything),
        );
      }
    },
  );
  test('scanner CSV retains quoted issuers and rejects malformed rows', () {
    expect(sniCsvRow('1.2.3.4,example.com,"Issuer, Inc.","a""b"'), [
      '1.2.3.4',
      'example.com',
      'Issuer, Inc.',
      'a"b',
    ]);
    expect(sniCsvRow('"unterminated'), isEmpty);
  });
  test(
    'one crashing scanner target does not discard the remaining search',
    () async {
      final work = await Directory.systemTemp.createTemp(
        'sky-ui-scanner-test-',
      );
      try {
        final binary = File('${work.path}/scanner');
        await binary.writeAsString(r'''#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in -in) input="$2";; -out) output="$2";; esac
  shift 2
done
if grep -q '177.177.212.62' "$input"; then exit 2; fi
printf 'IP,ORIGIN,TLS,ALPN,CURVE,CERT_DOMAIN\n' >"$output"
''');
        await Process.run('chmod', ['0755', binary.path]);
        final scanner = SniScanner(binary: binary.path);
        scanner.start('177.177.212.63');
        for (
          var i = 0;
          i < 100 && scanner.snapshot['status'] == 'running';
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(scanner.snapshot['status'], 'completed');
        expect(scanner.snapshot['completed'], 64);
        expect(scanner.snapshot['skipped'], 1);
        expect(scanner.snapshot['results'], isEmpty);
      } finally {
        await work.delete(recursive: true);
      }
    },
    skip: !SniScanner().supported,
  );
  test('cancellation terminates concurrent scanner processes', () async {
    final work = await Directory.systemTemp.createTemp(
      'sky-ui-scanner-cancel-',
    );
    try {
      final binary = File('${work.path}/scanner');
      await binary.writeAsString('#!/bin/sh\nexec sleep 20\n');
      await Process.run('chmod', ['0755', binary.path]);
      final scanner = SniScanner(binary: binary.path);
      scanner.start('177.177.212.63');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      scanner.cancel(scanner.snapshot['id'] as String);
      for (var i = 0; i < 60 && scanner.snapshot['status'] == 'running'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(scanner.snapshot['status'], 'cancelled');
    } finally {
      await work.delete(recursive: true);
    }
  }, skip: !SniScanner().supported);
}
