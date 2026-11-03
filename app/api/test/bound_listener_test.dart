import 'dart:io';
import 'package:sky_ui_api/src/infrastructure/network/socket_owner.dart';
import 'package:test/test.dart';

void main() {
  for (final host in ['127.0.0.1', '::1'])
    test(
      'TCP and UDP bindings at $host require the exact address, protocol and UID',
      () async {
        final tcp = await ServerSocket.bind(host, 0);
        final udp = await RawDatagramSocket.bind(
          host,
          tcp.port,
          reuseAddress: false,
          reusePort: false,
        );
        try {
          final uid = await processUid(pid);
          expect(
            await boundSocketBelongsTo(host, tcp.port, uid, udp: false),
            isTrue,
          );
          expect(
            await boundSocketBelongsTo(host, tcp.port, uid, udp: true),
            isTrue,
          );
          expect(
            await boundSocketBelongsTo(host, tcp.port, uid + 1, udp: false),
            isFalse,
          );
          expect(
            await boundSocketBelongsTo(host, tcp.port, uid + 1, udp: true),
            isFalse,
          );
        } finally {
          udp.close();
          await tcp.close();
        }
      },
      skip: !Platform.isLinux,
    );
}
