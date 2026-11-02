import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_ops/src/host.dart';
import 'package:sky_ui_ops/src/certificates.dart';

Future<void> main(List<String> args) async {
  require(
    Platform.isLinux && host.uid() == 0 && args.length == 1,
    'Pass verified mihomo binary as Linux root.',
  );
  final binary = File(args.single).absolute.path;
  await temporary('/var/tmp', 'sky-ui-certificate-test-', (root) async {
    final source = '$root/source',
        destination = '$root/published',
        issuer =
            '$root/source/acme-v02.api.letsencrypt.org-directory/fixture.example.test';
    Directory(issuer).createSync(recursive: true);
    final ca = '$root/ca.pem', caKey = '$root/ca.key';
    await run([
      'openssl',
      'req',
      '-x509',
      '-newkey',
      'ec',
      '-pkeyopt',
      'ec_paramgen_curve:P-256',
      '-nodes',
      '-days',
      '2',
      '-subj',
      '/CN=Sky UI private fixture CA',
      '-addext',
      'basicConstraints=critical,CA:TRUE',
      '-keyout',
      caKey,
      '-out',
      ca,
    ]);
    File('$root/extensions').writeAsStringSync(
      'subjectAltName=DNS:fixture.example.test\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n',
    );
    Future<String> issue() async {
      await run([
        'openssl',
        'req',
        '-new',
        '-newkey',
        'ec',
        '-pkeyopt',
        'ec_paramgen_curve:P-256',
        '-nodes',
        '-subj',
        '/CN=fixture.example.test',
        '-keyout',
        '$issuer/fixture.example.test.key',
        '-out',
        '$root/leaf.csr',
      ]);
      await run([
        'openssl',
        'x509',
        '-req',
        '-in',
        '$root/leaf.csr',
        '-CA',
        ca,
        '-CAkey',
        caKey,
        '-CAcreateserial',
        '-days',
        '1',
        '-extfile',
        '$root/extensions',
        '-out',
        '$issuer/fixture.example.test.crt',
      ]);
      final result = await syncCertificates(
        source: source,
        destination: destination,
        hosts: ['fixture.example.test'],
        primary: 'fixture.example.test',
        sourceUid: 0,
        gid: 0,
      );
      return result['panel']['fingerprint'] as String;
    }

    final first = await issue();
    Future<int> freePort() async {
      final s = await ServerSocket.bind('127.0.0.1', 0);
      final p = s.port;
      await s.close();
      return p;
    }

    final port = await freePort(),
        socks = await freePort(),
        marker = randomId();
    final echo = await HttpServer.bind('127.0.0.1', 0);
    final echoTask = echo.forEach((r) {
      r.response.write(marker);
      unawaited(r.response.close());
    });
    const uuid = '00000000-0000-4000-8000-000000000123';
    final configs = <String, Map<String, dynamic>>{
      'server': {
        'mode': 'rule',
        'log-level': 'silent',
        'rules': ['MATCH,DIRECT'],
        'listeners': [
          {
            'name': 'certificate-fixture',
            'type': 'vless',
            'listen': '127.0.0.1',
            'port': port,
            'users': [
              {'username': 'fixture', 'uuid': uuid},
            ],
            'certificate': '$destination/panel/fullchain.pem',
            'private-key': '$destination/panel/private.key',
          },
        ],
      },
      'client': {
        'mixed-port': socks,
        'allow-lan': false,
        'mode': 'rule',
        'log-level': 'silent',
        'tls': {
          'custom-certifactes': [File(ca).readAsStringSync()],
        },
        'proxies': [
          {
            'name': 'fixture',
            'type': 'vless',
            'server': '127.0.0.1',
            'port': port,
            'uuid': uuid,
            'tls': true,
            'servername': 'fixture.example.test',
            'client-fingerprint': 'chrome',
          },
        ],
        'proxy-groups': [
          {
            'name': 'Fixture',
            'type': 'select',
            'proxies': ['fixture'],
          },
        ],
        'rules': ['MATCH,Fixture'],
      },
    };
    final children = <Process>[], logs = <Future<void>>[];
    try {
      for (final entry in configs.entries) {
        final home = '$root/${entry.key}';
        Directory(home).createSync();
        File('$home/config.json').writeAsStringSync(jsonEncode(entry.value));
        final p = await Process.start(
          binary,
          ['-d', home, '-f', '$home/config.json'],
          environment: {...Platform.environment, 'SAFE_PATHS': destination},
        );
        children.add(p);
        final out = File('$home/native.log').openWrite();
        final a = p.stdout.listen(out.add), b = p.stderr.listen(out.add);
        logs.add(
          Future.wait([a.asFuture<void>(), b.asFuture<void>()])
              .then((_) => out.close()),
        );
      }
      final context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(ca);
      Future<String> observed() async {
        final raw = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(seconds: 2),
        );
        final tls = await SecureSocket.secure(
          raw,
          host: 'fixture.example.test',
          context: context,
        );
        try {
          return digest(tls.peerCertificate!.der);
        } finally {
          tls.destroy();
        }
      }

      Future<void> waitFor(String expected) async {
        final end = DateTime.now().add(const Duration(seconds: 20));
        while (DateTime.now().isBefore(end)) {
          try {
            if (await observed() == expected) return;
          } on Object {}
          await sleep(150);
        }
        throw const OpsError('native_certificate_reload_failed');
      }

      Future<void> traffic() async {
        final response = await run([
          'curl',
          '--fail',
          '--silent',
          '--max-time',
          '8',
          '--noproxy',
          '',
          '--socks5-hostname',
          '127.0.0.1:$socks',
          'http://127.0.0.1:${echo.port}/',
        ]);
        require(response == marker, 'renewal_traffic_failed');
      }

      await waitFor(first);
      await traffic();
      final second = await issue();
      require(first != second, 'fixture_certificate_not_rotated');
      await waitFor(second);
      await traffic();
      stdout.writeln(
        'PASS: trusted TLS certificate rotation and proxy traffic without native process restart.',
      );
    } finally {
      for (final p in children) p.kill();
      for (final p in children) {
        try {
          await p.exitCode.timeout(const Duration(seconds: 3));
        } on TimeoutException {
          p.kill(ProcessSignal.sigkill);
          await p.exitCode;
        }
      }
      await echo.close(force: true);
      await echoTask;
      await Future.wait(logs);
    }
  });
}
