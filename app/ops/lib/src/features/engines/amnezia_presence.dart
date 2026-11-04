import 'dart:convert';
import 'dart:io';

import '../../platform/host.dart';

/// The root worker reads UAPI locally. Only a peer fingerprint and time are
/// emitted, never the raw reply, which also contains private and preshared keys.
Future<void> observeAwgHandshakes(
  String name,
  Set<String> peers,
  Map<String, int> previous,
) async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      InternetAddress(
        '/run/amneziawg/$name.sock',
        type: InternetAddressType.unix,
      ),
      0,
      timeout: const Duration(seconds: 1),
    );
    final connection = socket;
    final reply = await (() async {
      connection.write('get=1\n\n');
      await connection.flush();
      final bytes = <int>[];
      await for (final chunk in connection) {
        if (bytes.length + chunk.length > 512 * 1024)
          throw const FormatException();
        bytes.addAll(chunk);
        if (bytes.length >= 2 &&
            bytes[bytes.length - 1] == 10 &&
            bytes[bytes.length - 2] == 10)
          break;
      }
      return utf8.decode(bytes);
    })().timeout(const Duration(seconds: 1));
    if (!reply.endsWith('errno=0\n\n')) return;
    String? peer;
    for (final line in const LineSplitter().convert(reply)) {
      if (line.startsWith('public_key=')) {
        final key = line.substring('public_key='.length);
        peer = peers.contains(key) ? key : null;
      } else if (peer != null && line.startsWith('last_handshake_time_sec=')) {
        final timestamp = int.tryParse(
          line.substring('last_handshake_time_sec='.length),
        );
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        if (timestamp == null ||
            timestamp > now ||
            now - timestamp > 180 ||
            timestamp <= (previous[peer] ?? 0))
          continue;
        previous[peer] = timestamp;
        stdout.writeln(
          'sky-ui-peer-handshake ${digest(utf8.encode('$name/$peer'))} $timestamp',
        );
      }
    }
  } on Exception {
    // Presence is optional and must never affect the tunnel lifecycle.
  } finally {
    socket?.destroy();
  }
}
