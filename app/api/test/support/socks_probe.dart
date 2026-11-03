import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

final _allocatedPorts = <int>{};
Future<int> freeProxyPort() async {
  // Keep native listeners outside the OS ephemeral pool used by probe clients.
  for (var attempt = 0; attempt < 100; attempt++) {
    final port = 20000 + Random.secure().nextInt(20000);
    if (!_allocatedPorts.add(port)) continue;
    ServerSocket? tcp;
    RawDatagramSocket? udp;
    try {
      tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      udp = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        reuseAddress: false,
        reusePort: false,
      );
      return port;
    } on SocketException {
      continue;
    } finally {
      await tcp?.close();
      udp?.close();
    }
  }
  throw StateError('No native test listener port available');
}

class _Reader {
  _Reader(Socket socket) : input = StreamIterator<List<int>>(socket);
  final StreamIterator<List<int>> input;
  final buffer = <int>[];
  Future<List<int>> read(int count) async {
    while (buffer.length < count) {
      if (!await input.moveNext().timeout(const Duration(seconds: 3)))
        throw StateError('SOCKS closed');
      buffer.addAll(input.current);
    }
    final out = buffer.sublist(0, count);
    buffer.removeRange(0, count);
    return out;
  }

  Future<List<int>> address(int type) async => read(
    type == 1
        ? 4
        : type == 4
        ? 16
        : (await read(1)).single,
  );
  Future<String> remaining() async {
    final out = <int>[...buffer];
    buffer.clear();
    while (await input.moveNext().timeout(const Duration(seconds: 3))) {
      out.addAll(input.current);
      if (out.length > 65536) throw StateError('Response too large');
    }
    return utf8.decode(out, allowMalformed: true);
  }
}

/// Native-test targets stay on loopback and use synthetic DNS names only.
class SocksProbe {
  late HttpServer http;
  late RawDatagramSocket udp, dns;
  int dnsQueries = 0;
  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) {
      req.response.write('sky-settings-ok');
      unawaited(req.response.close());
    });
    udp = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    udp.listen((e) {
      if (e == RawSocketEvent.read) {
        final p = udp.receive();
        if (p != null) udp.send(p.data, p.address, p.port);
      }
    });
    dns = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    dns.listen((e) {
      if (e != RawSocketEvent.read) return;
      final p = dns.receive();
      if (p == null || p.data.length < 17) return;
      final data = p.data;
      var end = 12;
      while (end < data.length && data[end] != 0) {
        end += data[end] + 1;
      }
      end += 5;
      if (end > data.length) return;
      dnsQueries++;
      final isA = data[end - 4] == 0 && data[end - 3] == 1;
      final response = <int>[
        data[0],
        data[1],
        0x81,
        0x80,
        0,
        1,
        0,
        isA ? 1 : 0,
        0,
        0,
        0,
        0,
        ...data.sublist(12, end),
        if (isA) ...[0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 127, 0, 0, 1],
      ];
      dns.send(response, p.address, p.port);
    });
  }

  List<int> _address(String host) {
    final ip = InternetAddress.tryParse(host);
    if (ip != null)
      return [ip.type == InternetAddressType.IPv4 ? 1 : 4, ...ip.rawAddress];
    final bytes = utf8.encode(host);
    return [3, bytes.length, ...bytes];
  }

  Future<bool> tcp(int port, {String host = '127.0.0.1'}) async {
    final socket = await Socket.connect('127.0.0.1', port);
    final reader = _Reader(socket);
    try {
      socket.add([5, 1, 0]);
      if ((await reader.read(2))[1] != 0) return false;
      socket.add([5, 1, 0, ..._address(host), http.port >> 8, http.port & 255]);
      final header = await reader.read(4);
      if (header[1] != 0) return false;
      await reader.address(header[3]);
      await reader.read(2);
      socket.add(utf8.encode('GET / HTTP/1.0\r\nHost: $host\r\n\r\n'));
      return (await reader.remaining()).contains('sky-settings-ok');
    } on Object {
      return false;
    } finally {
      await reader.input.cancel();
      socket.destroy();
    }
  }

  Future<bool> datagram(int port, {String host = '127.0.0.1'}) async {
    final socket = await Socket.connect('127.0.0.1', port);
    final reader = _Reader(socket);
    RawDatagramSocket? transport;
    try {
      socket.add([5, 1, 0]);
      if ((await reader.read(2))[1] != 0) throw StateError('SOCKS auth');
      socket.add([5, 3, 0, 1, 0, 0, 0, 0, 0, 0]);
      final header = await reader.read(4);
      if (header[1] != 0) throw StateError('SOCKS UDP unsupported');
      final address = await reader.address(header[3]),
          endpoint = await reader.read(2);
      final relay = address.every((b) => b == 0)
          ? InternetAddress.loopbackIPv4
          : InternetAddress.fromRawAddress(Uint8List.fromList(address));
      transport = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      final reply = Completer<bool>();
      transport.listen((e) {
        if (e == RawSocketEvent.read) {
          final packet = transport!.receive();
          if (packet != null && !reply.isCompleted)
            reply.complete(packet.data.last == 42);
        }
      });
      transport.send(
        [0, 0, 0, ..._address(host), udp.port >> 8, udp.port & 255, 42],
        relay,
        endpoint[0] * 256 + endpoint[1],
      );
      return await reply.future.timeout(
        const Duration(milliseconds: 800),
        onTimeout: () => false,
      );
    } finally {
      transport?.close();
      await reader.input.cancel();
      socket.destroy();
    }
  }

  Future<void> close() async {
    await http.close(force: true);
    udp.close();
    dns.close();
  }
}
