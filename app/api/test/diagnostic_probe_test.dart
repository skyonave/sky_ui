import 'dart:io';
import 'package:sky_ui_api/src/application/contracts/connection_diagnostics.dart';
import 'package:sky_ui_api/src/infrastructure/network/diagnostic_probe.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';

void main() {
  const remote = DiagnosticTlsTarget(
    host: 'handshake.example',
    port: 443,
    serverName: 'sni.example',
    remote: true,
    tls13: true,
  );
  for (final address in [
    '0.0.0.0',
    '10.1.2.3',
    '127.0.0.1',
    '169.254.169.254',
    '172.16.0.1',
    '192.168.0.1',
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
    test(
      'remote target rejects $address',
      () => expect(publicDiagnosticAddress(InternetAddress(address)), isFalse),
    );
  }
  test('public IPv4 and IPv6 are accepted', () {
    expect(publicDiagnosticAddress(InternetAddress('1.1.1.1')), isTrue);
    expect(
      publicDiagnosticAddress(InternetAddress('2001:4860:4860::8888')),
      isTrue,
    );
  });
  test('mixed public/private DNS result fails closed', () async {
    final probe = NativeDiagnosticProbe(
      lookup: (_) async => [
        InternetAddress('1.1.1.1'),
        InternetAddress('127.0.0.1'),
      ],
    );
    final result = await probe.resolve(remote, DiagnosticCancellation());
    expect(result.result.code, 'target_not_public');
    expect(result.addresses, isEmpty);
  });
  test(
    'bounded address selection retains both families without resolving SNI again',
    () async {
      final names = <String>[];
      final probe = NativeDiagnosticProbe(
        lookup: (name) async {
          names.add(name);
          return [
            InternetAddress('1.1.1.1'),
            InternetAddress('8.8.8.8'),
            InternetAddress('2606:4700:4700::1111'),
          ];
        },
      );
      final result = await probe.resolve(remote, DiagnosticCancellation());
      expect(names, ['handshake.example']);
      expect(result.addresses, ['1.1.1.1', '2606:4700:4700::1111']);
    },
  );
  test(
    'TCP probe connects to an explicit local listener and reports failure after close',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((socket) => socket.destroy());
      final target = DiagnosticTlsTarget(
        host: '127.0.0.1',
        port: server.port,
        serverName: 'localhost',
        remote: false,
      );
      final probe = NativeDiagnosticProbe();
      expect(
        (await probe.tcp(target, ['127.0.0.1'], DiagnosticCancellation())).code,
        'tcp_ready',
      );
      await subscription.cancel();
      await server.close();
      expect(
        (await probe.tcp(target, ['127.0.0.1'], DiagnosticCancellation())).code,
        Platform.isWindows ? anyOf('tcp_refused', 'tcp_failed') : 'tcp_refused',
      );
    },
  );
  test(
    'remote TCP and TLS refuse loopback even when called without resolution',
    () async {
      final probe = NativeDiagnosticProbe();
      expect(
        (await probe.tcp(remote, ['127.0.0.1'], DiagnosticCancellation())).code,
        'target_not_public',
      );
      expect(
        (await probe.tls(remote, '127.0.0.1', DiagnosticCancellation())).state,
        DiagnosticState.failed,
      );
    },
  );
  test(
    'Linux verifies actual TCP/UDP binding ownership and missing interfaces',
    () async {
      final tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final probe = NativeDiagnosticProbe();
      final tcpListener = DiagnosticListener(
        host: '127.0.0.1',
        port: tcp.port,
        udp: false,
      );
      final udpListener = DiagnosticListener(
        host: '127.0.0.1',
        port: udp.port,
        udp: true,
      );
      try {
        for (final listener in [tcpListener, udpListener]) {
          expect(
            (await probe.listener(
              listener,
              pid,
              DiagnosticCancellation(),
            )).code,
            'listener_ready',
          );
        }
        expect(
          (await probe.listener(
            tcpListener,
            null,
            DiagnosticCancellation(),
          )).code,
          'listener_identity_unavailable',
        );
        expect(
          (await probe.listener(
            DiagnosticListener(
              host: '127.0.0.1',
              port: tcp.port,
              udp: false,
              interfaceName: 'invalid-interface',
            ),
            pid,
            DiagnosticCancellation(),
          )).code,
          'interface_missing',
        );
      } finally {
        await tcp.close();
        udp.close();
      }
      for (final listener in [tcpListener, udpListener]) {
        expect(
          (await probe.listener(listener, pid, DiagnosticCancellation())).code,
          'listener_missing',
        );
      }
    },
    skip: !Platform.isLinux ? 'Linux socket ownership requires /proc.' : false,
  );
  test('bad SNI cannot become process arguments', () async {
    final probe = NativeDiagnosticProbe();
    const target = DiagnosticTlsTarget(
      host: '1.1.1.1',
      port: 443,
      serverName: '-keylogfile\n/private',
      remote: true,
    );
    expect(
      (await probe.resolve(target, DiagnosticCancellation())).result.code,
      'target_invalid',
    );
    expect(
      (await probe.tls(target, '1.1.1.1', DiagnosticCancellation())).code,
      'target_invalid',
    );
  });
  test(
    'TLS success requires verified certificate and the requested protocol',
    () {
      const good =
          'CONNECTION ESTABLISHED\nProtocol version: TLSv1.3\nCiphersuite: TLS_AES_128_GCM_SHA256\nVerification: OK\nprivate-session-fixture';
      final result = parseTlsProbe(0, good, requireTls13: true);
      expect(result.state, DiagnosticState.passed);
      expect(result.details, {
        'protocol': 'TLSv1.3',
        'cipher': 'TLS_AES_128_GCM_SHA256',
      });
      expect(
        parseTlsProbe(
          0,
          good.replaceAll('TLSv1.3', 'TLSv1.2'),
          requireTls13: true,
        ).code,
        'tls_version',
      );
      expect(
        parseTlsProbe(1, good, requireTls13: true).state,
        DiagnosticState.failed,
      );
      expect(
        parseTlsProbe(
          0,
          good.replaceAll('Verification: OK', ''),
          requireTls13: true,
        ).state,
        DiagnosticState.failed,
      );
    },
  );
  for (final entry in {
    '62': 'tls_name_mismatch',
    '64': 'tls_name_mismatch',
    '9': 'tls_not_yet_valid',
    '10': 'tls_expired',
    '18': 'tls_untrusted',
    '20': 'tls_untrusted',
  }.entries) {
    test(
      'certificate error ${entry.key} has an actionable code',
      () => expect(
        parseTlsProbe(
          1,
          'verify error:num=${entry.key}:fixture secret-output',
          requireTls13: false,
        ).code,
        entry.value,
      ),
    );
  }
}
