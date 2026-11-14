import 'dart:async';
import 'dart:io';

import 'package:sky_ui_ops/src/features/servers/node_diagnostics.dart';
import 'package:test/test.dart';

void main() {
  group(
    'native remote-node TLS probes',
    () {
      late Directory directory;
      late SecureServerSocket server;
      late StreamSubscription<SecureSocket> accepted;
      late String certificate;
      final sockets = <SecureSocket>{};
      setUp(() async {
        directory = await Directory.systemTemp.createTemp('sky-node-tls-');
        certificate = '${directory.path}/cert.pem';
        final key = '${directory.path}/key.pem';
        final generated = await Process.run('/usr/bin/openssl', [
          'req',
          '-x509',
          '-newkey',
          'rsa:2048',
          '-nodes',
          '-keyout',
          key,
          '-out',
          certificate,
          '-days',
          '1',
          '-subj',
          '/CN=localhost',
          '-addext',
          'subjectAltName=DNS:localhost',
        ]);
        expect(generated.exitCode, 0);
        server = await SecureServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
          SecurityContext()
            ..useCertificateChain(certificate)
            ..usePrivateKey(key),
          supportedProtocols: ['h2', 'http/1.1'],
        );
        accepted = server.listen((socket) {
          sockets.add(socket);
          socket.listen(
            (_) {},
            onError: (_) {},
            onDone: () {
              sockets.remove(socket);
              socket.destroy();
            },
          );
        }, onError: (_) {});
      });
      tearDown(() async {
        for (final socket in [...sockets]) {
          socket.destroy();
        }
        sockets.clear();
        await accepted.cancel();
        await server.close();
        if (directory.absolute.parent.uri != Directory.systemTemp.absolute.uri)
          throw StateError('Unexpected fixture path');
        await directory.delete(recursive: true);
      });
      Map<String, dynamic> target([String sni = 'localhost']) => {
        'stage': 'tls',
        'host': '127.0.0.1',
        'port': server.port,
        'serverName': sni,
        'remote': false,
        'tls13': true,
        'addresses': ['127.0.0.1'],
      };
      test('verifies TLS1.3 and exposes only protocol/cipher', () async {
        final value = await NodeDiagnosticProbe(trustedCAFile: certificate)
            .run(target(), localTcpPorts: {server.port});
        expect(value['code'], 'tls_ready');
        expect((value['details'] as Map)['protocol'], 'TLSv1.3');
        expect(
          (value['details'] as Map).keys,
          unorderedEquals(['protocol', 'cipher']),
        );
      });
      test('untrusted certificate and incorrect SNI fail closed', () async {
        expect(
          (await NodeDiagnosticProbe().run(
            target(),
            localTcpPorts: {server.port},
          ))['code'],
          'tls_untrusted',
        );
        expect(
          (await NodeDiagnosticProbe(
            trustedCAFile: certificate,
          ).run(target('wrong.example'), localTcpPorts: {server.port}))['code'],
          'tls_name_mismatch',
        );
      });
    },
    skip: !Platform.isLinux || !File('/usr/bin/openssl').existsSync()
        ? 'Requires native Linux OpenSSL.'
        : false,
  );
}
