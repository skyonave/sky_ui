import 'dart:async';
import 'dart:io';

import 'package:sky_ui_ops/src/features/servers/node_diagnostics.dart';
import 'package:test/test.dart';

Map<String, dynamic> request(
  String stage, {
  String host = 'target.example',
  int port = 443,
  bool remote = true,
  List<String> addresses = const [],
  String serverName = 'target.example',
}) => {
  'stage': stage,
  'host': host,
  'port': port,
  'serverName': serverName,
  'remote': remote,
  'tls13': true,
  'addresses': addresses,
};

void main() {
  test(
    'rejects private, mapped, documentation and multicast remote targets',
    () async {
      for (final address in [
        '0.0.0.0',
        '10.1.2.3',
        '127.0.0.1',
        '169.254.169.254',
        '172.16.1.1',
        '192.168.1.1',
        '100.64.0.1',
        '198.18.0.1',
        '192.0.2.1',
        '198.51.100.1',
        '203.0.113.1',
        '224.0.0.1',
        '255.255.255.255',
        '::1',
        '::',
        'fc00::1',
        'fe80::1',
        'ff02::1',
        '2001:db8::1',
        '::ffff:127.0.0.1',
      ]) {
        expect(
          publicNodeProbeAddress(InternetAddress(address)),
          isFalse,
          reason: address,
        );
        final value = await NodeDiagnosticProbe().run(
          request('dns', host: address),
        );
        expect(value['code'], 'target_not_public', reason: address);
      }
      expect(publicNodeProbeAddress(InternetAddress('1.1.1.1')), isTrue);
      expect(
        publicNodeProbeAddress(InternetAddress('2606:4700:4700::1111')),
        isTrue,
      );
    },
  );
  test(
    'rejects mixed DNS results and retains one address of each family',
    () async {
      final mixed = NodeDiagnosticProbe(
        lookup: (_) async => [
          InternetAddress('1.1.1.1'),
          InternetAddress('127.0.0.1'),
        ],
      );
      expect((await mixed.run(request('dns')))['code'], 'target_not_public');
      final names = <String>[];
      final probe = NodeDiagnosticProbe(
        lookup: (name) async {
          names.add(name);
          return [
            InternetAddress('1.1.1.1'),
            InternetAddress('8.8.8.8'),
            InternetAddress('2606:4700:4700::1111'),
          ];
        },
      );
      final resolved = await probe.run(request('dns'));
      expect(names, ['target.example']);
      expect(resolved['addresses'], ['1.1.1.1', '2606:4700:4700::1111']);
    },
  );
  test(
    'malformed requests and caller-selected trust/executables are rejected',
    () async {
      final probe = NodeDiagnosticProbe();
      for (final value in [
        {...request('dns'), 'port': '443'},
        {...request('dns'), 'serverName': '-CAfile /tmp/evil'},
        {...request('dns'), 'host': 'https://example.org'},
        {...request('dns'), 'trustedCAFile': '/tmp/evil'},
        {...request('dns'), 'opensslExecutable': '/tmp/evil'},
        {
          ...request('tcp'),
          'addresses': ['1.1.1.1', '8.8.8.8', '9.9.9.9'],
        },
        request('tls'),
        request('exec'),
      ]) {
        expect((await probe.run(value))['code'], 'target_invalid');
      }
      expect(
        (await probe.run(request('tcp', addresses: ['127.0.0.1'])))['code'],
        'target_not_public',
      );
    },
  );
  test(
    'local checks require loopback and verified native listener port',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = server.listen((socket) => socket.destroy());
      final probe = NodeDiagnosticProbe();
      final local = request(
        'tcp',
        host: '127.0.0.1',
        port: server.port,
        remote: false,
        addresses: ['127.0.0.1'],
      );
      try {
        expect((await probe.run(local))['code'], 'target_invalid');
        expect(
          (await probe.run(local, localTcpPorts: {server.port}))['code'],
          'tcp_ready',
        );
        expect(
          (await probe.run(
            {...local, 'host': 'localhost'},
            localTcpPorts: {server.port},
          ))['code'],
          'target_invalid',
        );
        expect(
          (await probe.run(
            {
              ...local,
              'addresses': ['1.1.1.1'],
            },
            localTcpPorts: {server.port},
          ))['code'],
          'target_invalid',
        );
      } finally {
        await accepted.cancel();
        await server.close();
      }
      expect(
        (await probe.run(local, localTcpPorts: {local['port'] as int}))['code'],
        anyOf('tcp_refused', 'tcp_failed'),
      );
    },
  );
  test(
    'DNS deadline and cancellation stop waiting for a stalled lookup',
    () async {
      final pending = Completer<List<InternetAddress>>();
      final probe = NodeDiagnosticProbe(
        timeout: const Duration(milliseconds: 80),
        lookup: (_) => pending.future,
      );
      expect((await probe.run(request('dns')))['code'], 'dns_timeout');
      final cancellation = NodeProbeCancellation();
      final work = NodeDiagnosticProbe(lookup: (_) => pending.future)
          .run(request('dns'), cancellation: cancellation);
      cancellation.cancel();
      expect(
        (await work.timeout(const Duration(seconds: 1)))['code'],
        'check_failed',
      );
    },
  );
  test(
    'TLS output exposes only verified protocol/cipher and classified errors',
    () {
      final passed = parseNodeTlsProbe(
        0,
        'Protocol version: TLSv1.3\nCiphersuite: TLS_AES_256_GCM_SHA384\nVerification: OK\nSECRET SESSION DATA',
        requireTls13: true,
      );
      expect(passed['code'], 'tls_ready');
      expect(passed['details'], {
        'protocol': 'TLSv1.3',
        'cipher': 'TLS_AES_256_GCM_SHA384',
      });
      expect(passed.toString(), isNot(contains('SECRET')));
      for (final entry in {
        '62': 'tls_name_mismatch',
        '10': 'tls_expired',
        '20': 'tls_untrusted',
      }.entries) {
        expect(
          parseNodeTlsProbe(
            1,
            'verify error:num=${entry.key}:raw certificate text',
            requireTls13: true,
          )['code'],
          entry.value,
        );
      }
      expect(
        parseNodeTlsProbe(
          0,
          'Protocol version: TLSv1.2\nVerification: OK',
          requireTls13: true,
        )['code'],
        'tls_version',
      );
      expect(
        parseNodeTlsProbe(
          0,
          'Protocol version: TLSv1.3',
          requireTls13: true,
        )['code'],
        'tls_failed',
      );
    },
  );
  test(
    'TLS timeout and cancellation terminate the owned child process',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sky-node-probe-',
      );
      final child = File('${directory.path}/stall.dart');
      await child.writeAsString(
        "import 'dart:async'; void main() { Timer.periodic(Duration(seconds: 1), (_) {}); }",
      );
      Process? running;
      final processes = <Process>[];
      Future<Process> start(List<String> arguments) async {
        expect(
          arguments,
          containsAll([
            '-verify_return_error',
            '-verify_hostname',
            '-tls1_3',
            '-servername',
            'target.example',
          ]),
        );
        running = await Process.start(Platform.resolvedExecutable, [
          child.path,
        ]);
        processes.add(running!);
        return running!;
      }

      final local = request(
        'tls',
        host: '127.0.0.1',
        port: 8443,
        remote: false,
        addresses: ['127.0.0.1'],
      );
      try {
        final probe = NodeDiagnosticProbe(
          timeout: const Duration(milliseconds: 100),
          startTls: start,
        );
        expect(
          (await probe.run(local, localTcpPorts: {8443}))['code'],
          'tls_timeout',
        );
        await running!.exitCode.timeout(const Duration(seconds: 1));
        final cancellation = NodeProbeCancellation();
        final timer = Timer(
          const Duration(milliseconds: 120),
          cancellation.cancel,
        );
        try {
          expect(
            (await NodeDiagnosticProbe(startTls: start).run(
              local,
              localTcpPorts: {8443},
              cancellation: cancellation,
            ))['code'],
            'check_failed',
          );
          await running!.exitCode.timeout(const Duration(seconds: 1));
        } finally {
          timer.cancel();
        }
      } finally {
        for (final process in processes) {
          process.kill();
        }
        if (directory.absolute.parent.uri != Directory.systemTemp.absolute.uri)
          throw StateError('Unexpected fixture path');
        await directory.delete(recursive: true);
      }
    },
  );
}
