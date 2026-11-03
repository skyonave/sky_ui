import 'dart:io';

import '../../shared/api_exception.dart';

Future<int> processUid(int processId) async {
  try {
    final status = await File('/proc/$processId/status').readAsString();
    final uid = RegExp(
      r'^Uid:\s+\d+\s+(\d+)',
      multiLine: true,
    ).firstMatch(status)?.group(1);
    if (uid != null) return int.parse(uid);
  } on FileSystemException {
    /* Fail closed when process identity cannot be read. */
  }
  throw const ApiException('listener_identity_unavailable');
}

String _normalized(List<int> bytes) {
  if (bytes.length == 16 &&
      bytes.take(10).every((v) => v == 0) &&
      bytes[10] == 255 &&
      bytes[11] == 255)
    bytes = bytes.sublist(12);
  return bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
}

String _kernelAddress(String hex) {
  final bytes = [
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  final ordered = [
    for (var i = 0; i < bytes.length; i += 4)
      ...bytes.sublist(i, i + 4).reversed,
  ];
  return _normalized(ordered);
}

// Check the accepted side of this exact probe, including IPv4-mapped IPv6.
// A foreign process occupying the port must never count as an applied listener.
Future<bool> peerBelongsTo(Socket socket, int uid) async {
  final local = _normalized(socket.address.rawAddress);
  final remote = _normalized(socket.remoteAddress.rawAddress);
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      for (final name in ['tcp', 'tcp6']) {
        final file = File('/proc/net/$name');
        if (!await file.exists()) continue;
        for (final line in (await file.readAsLines()).skip(1)) {
          final fields = line.trim().split(RegExp(r'\s+'));
          if (fields.length < 10 || fields[3] != '01') continue;
          final server = fields[1].split(':');
          final client = fields[2].split(':');
          if (int.parse(server[1], radix: 16) == socket.remotePort &&
              int.parse(client[1], radix: 16) == socket.port &&
              _kernelAddress(server[0]) == remote &&
              _kernelAddress(client[0]) == local &&
              int.parse(fields[7]) == uid)
            return true;
        }
      }
    } on FileSystemException {
      throw const ApiException('listener_identity_unavailable');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return false;
}

Future<bool> boundSocketBelongsTo(
  String host,
  int port,
  int uid, {
  required bool udp,
}) async {
  final expected = InternetAddress.tryParse(host);
  if (expected == null) return false;
  final address = _normalized(expected.rawAddress);
  try {
    for (final name in udp ? ['udp', 'udp6'] : ['tcp', 'tcp6']) {
      final file = File('/proc/net/$name');
      if (!await file.exists()) continue;
      for (final line in (await file.readAsLines()).skip(1)) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length < 10 || fields[3] != (udp ? '07' : '0A')) continue;
        final local = fields[1].split(':');
        if (int.parse(local[1], radix: 16) == port &&
            _kernelAddress(local[0]) == address &&
            int.parse(fields[7]) == uid)
          return true;
      }
    }
  } on FileSystemException {
    throw const ApiException('listener_identity_unavailable');
  }
  return false;
}
