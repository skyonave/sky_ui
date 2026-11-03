import 'dart:async';
import 'dart:io';
import 'package:sky_ui_api/src/application/contracts/connection_diagnostics.dart';
import 'package:sky_ui_api/src/infrastructure/network/diagnostic_probe.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';

void main() {
  group(
    'native OpenSSL TLS probes',
    () {
      late Directory work;
      late String cert, key;
      late SecureServerSocket server;
      late StreamSubscription<SecureSocket> subscription;
      final clients = <SecureSocket>{};
      setUp(() async {
        work = await Directory.systemTemp.createTemp('sky-ui-tls-probe-');
        cert = '${work.path}/cert.pem';
        key = '${work.path}/key.pem';
        final result = await Process.run('/usr/bin/openssl', [
          'req',
          '-x509',
          '-newkey',
          'rsa:2048',
          '-nodes',
          '-keyout',
          key,
          '-out',
          cert,
          '-days',
          '1',
          '-subj',
          '/CN=localhost',
          '-addext',
          'subjectAltName=DNS:localhost',
        ]);
        expect(result.exitCode, 0);
        final context = SecurityContext()
          ..useCertificateChain(cert)
          ..usePrivateKey(key);
        server = await SecureServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
          context,
          supportedProtocols: ['h2', 'http/1.1'],
        );
        subscription = server.listen((socket) {
          clients.add(socket);
          socket.listen(
            (_) {},
            onError: (_) {},
            onDone: () {
              clients.remove(socket);
              socket.destroy();
            },
          );
        }, onError: (_) {});
      });
      tearDown(() async {
        for (final socket in [...clients]) {
          socket.destroy();
        }
        clients.clear();
        await subscription.cancel();
        await server.close();
        if (work.absolute.parent.uri != Directory.systemTemp.absolute.uri)
          throw StateError('Unexpected fixture path');
        await work.delete(recursive: true);
      });
      DiagnosticTlsTarget target({String sni = 'localhost'}) =>
          DiagnosticTlsTarget(
            host: '127.0.0.1',
            port: server.port,
            serverName: sni,
            remote: false,
            tls13: true,
          );
      test(
        'verified TLS 1.3 handshake terminates at stdin EOF and exposes only safe metadata',
        () async {
          final probe = NativeDiagnosticProbe(trustedCAFile: cert);
          final result = await probe.tls(
            target(),
            '127.0.0.1',
            DiagnosticCancellation(),
          );
          expect(result.state, DiagnosticState.passed);
          expect(result.details['protocol'], 'TLSv1.3');
          expect(result.details.keys, unorderedEquals(['protocol', 'cipher']));
        },
      );
      test('untrusted chain and wrong SNI remain failures', () async {
        final untrusted = await NativeDiagnosticProbe().tls(
          target(),
          '127.0.0.1',
          DiagnosticCancellation(),
        );
        expect(untrusted.code, 'tls_untrusted');
        final mismatch = await NativeDiagnosticProbe(trustedCAFile: cert).tls(
          target(sni: 'wrong.example'),
          '127.0.0.1',
          DiagnosticCancellation(),
        );
        expect(mismatch.code, 'tls_name_mismatch');
      });
      test(
        'silent TCP endpoint times out and cancellation kills the handshake process',
        () async {
          final plain = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final sockets = <Socket>[];
          final listening = plain.listen(sockets.add);
          final silent = DiagnosticTlsTarget(
            host: '127.0.0.1',
            port: plain.port,
            serverName: 'localhost',
            remote: false,
          );
          try {
            final result = await NativeDiagnosticProbe(
              timeout: const Duration(milliseconds: 200),
            ).tls(silent, '127.0.0.1', DiagnosticCancellation());
            expect(result.code, 'tls_timeout');
            final cancellation = DiagnosticCancellation();
            final timer = Timer(
              const Duration(milliseconds: 100),
              cancellation.cancel,
            );
            try {
              await expectLater(
                NativeDiagnosticProbe().tls(silent, '127.0.0.1', cancellation),
                throwsA(isA<DiagnosticCancelled>()),
              );
            } finally {
              timer.cancel();
            }
          } finally {
            for (final socket in sockets) {
              socket.destroy();
            }
            await listening.cancel();
            await plain.close();
          }
        },
      );
    },
    skip: !Platform.isLinux || !File('/usr/bin/openssl').existsSync()
        ? 'Linux OpenSSL fixture required.'
        : false,
  );
}
