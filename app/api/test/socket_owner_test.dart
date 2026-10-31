import 'dart:io';
import 'package:sky_ui_api/src/cores/socket_owner.dart';
import 'package:test/test.dart';

void main() {
  for (final address in ['127.0.0.1', '::1']) {
    test('identifies accepted TCP peer at $address', () async {
      final server = await ServerSocket.bind(address, 0);
      final accepted = <Socket>[];
      final subscription = server.listen(accepted.add);
      final socket = await Socket.connect(address, server.port);
      try {
        expect(await peerBelongsTo(socket, await processUid(pid)), true);
      } finally {
        socket.destroy();
        for (final s in accepted) {
          s.destroy();
        }
        await subscription.cancel();
        await server.close();
      }
    }, skip: !Platform.isLinux);
  }
}
