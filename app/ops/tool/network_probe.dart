import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sky_ui_ops/src/host.dart';

class SocketBytes {
  SocketBytes(Socket socket) : chunks = StreamIterator(socket);
  final StreamIterator<Uint8List> chunks;
  final pending = <int>[];
  Future<List<int>> read(int length) async {
    while (pending.length < length) {
      require(
        await chunks.moveNext().timeout(const Duration(seconds: 3)),
        'socks_unexpected_eof',
      );
      pending.addAll(chunks.current);
    }
    final result = pending.sublist(0, length);
    pending.removeRange(0, length);
    return result;
  }
}

Future<void> probeUdp(int socks, int target, List<int> payload) async {
  final control = await Socket.connect(
    '127.0.0.1',
    socks,
    timeout: const Duration(seconds: 3),
  );
  final bytes = SocketBytes(control);
  RawDatagramSocket? udp;
  StreamSubscription<RawSocketEvent>? events;
  try {
    control.add([5, 1, 0]);
    await control.flush();
    require((await bytes.read(2)).join(',') == '5,0', 'socks_greeting_failed');
    control.add([5, 3, 0, 1, 0, 0, 0, 0, 0, 0]);
    await control.flush();
    final header = await bytes.read(4);
    require(header[0] == 5 && header[1] == 0, 'socks_udp_rejected');
    InternetAddress relay;
    if (header[3] == 1 || header[3] == 4) {
      relay = InternetAddress.fromRawAddress(
        Uint8List.fromList(await bytes.read(header[3] == 1 ? 4 : 16)),
      );
      if (relay.rawAddress.every((b) => b == 0))
        relay = InternetAddress.loopbackIPv4;
    } else {
      require(header[3] == 3, 'socks_address_invalid');
      final host = utf8.decode(await bytes.read((await bytes.read(1)).single));
      relay =
          InternetAddress.tryParse(host) ??
          (await InternetAddress.lookup(host)).first;
    }
    final portBytes = await bytes.read(2),
        port = portBytes[0] * 256 + portBytes[1];
    udp = await RawDatagramSocket.bind(
      relay.type == InternetAddressType.IPv6
          ? InternetAddress.loopbackIPv6
          : InternetAddress.loopbackIPv4,
      0,
    );
    final response = Completer<void>();
    events = udp.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? packet;
      while ((packet = udp!.receive()) != null) {
        final body = packet!.data;
        if (!response.isCompleted &&
            body.length >= payload.length &&
            digest(body.sublist(body.length - payload.length)) ==
                digest(payload))
          response.complete();
      }
    });
    final packet = [
      0,
      0,
      0,
      1,
      127,
      0,
      0,
      1,
      target >> 8,
      target & 255,
      ...payload,
    ];
    for (var attempt = 0; attempt < 3; attempt++) {
      udp.send(packet, relay, port);
      try {
        await response.future.timeout(const Duration(seconds: 3));
        return;
      } on TimeoutException {}
    }
    throw const OpsError('udp_payload_timeout');
  } finally {
    await events?.cancel();
    udp?.close();
    await bytes.chunks.cancel();
    control.destroy();
  }
}

void invalidateCredentials(Map<String, dynamic> proxy) {
  if (proxy.containsKey('uuid')) {
    proxy['uuid'] = '00000000-0000-4000-8000-${randomId(6)}';
  } else if (proxy.containsKey('username')) {
    proxy['username'] = 'rejected-${randomId(6)}';
  } else if (proxy.containsKey('password')) {
    proxy['password'] = proxy['cipher']?.toString().startsWith('2022-') == true
        ? (proxy['password'] as String)
              .split(':')
              .map(
                (part) => base64.encode(
                  List<int>.generate(
                    base64.decode(part).length,
                    (_) => int.parse(randomId(1), radix: 16),
                  ),
                ),
              )
              .join(':')
        : 'rejected-${randomId()}';
  } else {
    throw const OpsError('fixture_credential_mutation_missing');
  }
}
