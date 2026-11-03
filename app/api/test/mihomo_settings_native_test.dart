import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:sky_ui_api/src/engines/mihomo/settings.dart';
import 'package:test/test.dart';
import 'support/socks_probe.dart' show freeProxyPort;

/// Opt-in loopback-only acceptance; never changes host routes or running cores.
void main() {
  final binary = Platform.environment['SKY_UI_MIHOMO_BINARY'];
  test(
    'native mihomo applies scoped private/domain rules and DNS configurations',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sky-settings-native-',
      );
      Process? process;
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      target.listen((request) {
        request.response.write('settings-native-ok');
        unawaited(request.response.close());
      });
      final logs = StringBuffer();
      final udpTarget = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      udpTarget.listen((event) {
        if (event == RawSocketEvent.read) {
          final packet = udpTarget.receive();
          if (packet != null)
            udpTarget.send(packet.data, packet.address, packet.port);
        }
      });
      Future<bool> udpReaches(int port) async {
        final control = await Socket.connect('127.0.0.1', port);
        final input = StreamIterator<List<int>>(control);
        final buffered = <int>[];
        Future<List<int>> read(int count) async {
          while (buffered.length < count) {
            if (!await input.moveNext().timeout(const Duration(seconds: 2)))
              throw StateError('SOCKS closed');
            buffered.addAll(input.current);
          }
          final out = buffered.sublist(0, count);
          buffered.removeRange(0, count);
          return out;
        }

        RawDatagramSocket? socket;
        try {
          control.add([5, 1, 0]);
          expect(await read(2), [5, 0]);
          control.add([5, 3, 0, 1, 0, 0, 0, 0, 0, 0]);
          final header = await read(4);
          expect(header.sublist(0, 2), [5, 0]);
          final address = await read(header[3] == 1 ? 4 : 16),
              endpoint = await read(2);
          socket = await RawDatagramSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final reply = Completer<bool>();
          socket.listen((event) {
            if (event == RawSocketEvent.read) {
              final packet = socket!.receive();
              if (packet != null && !reply.isCompleted)
                reply.complete(packet.data.last == 42);
            }
          });
          final targetAddress = InternetAddress.fromRawAddress(
            Uint8List.fromList(address),
          );
          socket.send(
            [
              0,
              0,
              0,
              1,
              127,
              0,
              0,
              1,
              udpTarget.port >> 8,
              udpTarget.port & 255,
              42,
            ],
            address.every((byte) => byte == 0)
                ? InternetAddress.loopbackIPv4
                : targetAddress,
            endpoint[0] * 256 + endpoint[1],
          );
          return await reply.future.timeout(
            const Duration(milliseconds: 700),
            onTimeout: () => false,
          );
        } finally {
          socket?.close();
          await input.cancel();
          control.destroy();
        }
      }

      Future<({int owned, int foreign})> start(
        Map<String, String> input,
      ) async {
        if (process != null) {
          process!.kill();
          await process!.exitCode;
          process = null;
        }
        final owned = await freeProxyPort(), foreign = await freeProxyPort();
        final listener = <String, Object?>{
          'name': 'sky-ui/test',
          'type': 'mixed',
          'listen': '127.0.0.1',
          'port': owned,
          'proxy': 'DIRECT',
        };
        final base = <String, Object?>{
          'mode': 'direct',
          'log-level': 'warning',
          'ipv6': false,
          'hosts': {'blocked.test': '127.0.0.1', 'private.test': '127.0.0.1'},
          'listeners': [
            listener,
            {
              'name': 'foreign',
              'type': 'mixed',
              'listen': '127.0.0.1',
              'port': foreign,
              'proxy': 'DIRECT',
            },
          ],
        };
        final values = MihomoSettings.prepare(jsonEncode(base), null, input);
        MihomoSettings.apply(base, [listener], values);
        final file = File('${directory.path}/config.json');
        await file.writeAsString(jsonEncode(base));
        final validation = await Process.run(binary!, [
          '-t',
          '-d',
          directory.path,
          '-f',
          file.path,
        ]);
        expect(
          validation.exitCode,
          0,
          reason: '${validation.stdout}\n${validation.stderr}',
        );
        process = await Process.start(binary, [
          '-d',
          directory.path,
          '-f',
          file.path,
        ]);
        void collect(String value) {
          if (logs.length < 32768) logs.write(value);
        }

        process!.stdout.transform(utf8.decoder).listen(collect);
        process!.stderr.transform(utf8.decoder).listen(collect);
        var ready = false;
        for (var i = 0; i < 50; i++) {
          try {
            final socket = await Socket.connect(
              '127.0.0.1',
              owned,
              timeout: const Duration(milliseconds: 100),
            );
            socket.destroy();
            ready = true;
            break;
          } on SocketException {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        }
        expect(ready, true, reason: logs.toString());
        return (owned: owned, foreign: foreign);
      }

      Future<bool> reaches(int port, String host) async {
        final client = HttpClient()..findProxy = (_) => 'PROXY 127.0.0.1:$port';
        try {
          final request = await client.getUrl(
            Uri.parse('http://$host:${target.port}/'),
          );
          final response = await request.close().timeout(
            const Duration(seconds: 3),
          );
          final body = await utf8.decoder
              .bind(response)
              .join()
              .timeout(const Duration(seconds: 3));
          return response.statusCode == 200 && body == 'settings-native-ok';
        } on Object {
          return false;
        } finally {
          client.close(force: true);
        }
      }

      try {
        var ports = await start({'logLevel': 'debug'});
        expect(await reaches(ports.owned, '127.0.0.1'), true);
        expect(
          await udpReaches(ports.owned),
          true,
          reason: 'baseline UDP must reach loopback\n$logs',
        );
        ports = await start({
          'blockPrivate': 'true',
          'dnsMode': 'system',
          'logLevel': 'debug',
        });
        expect(
          await reaches(ports.owned, '127.0.0.1'),
          false,
          reason: 'private IP must be rejected',
        );
        expect(
          await reaches(ports.owned, 'private.test'),
          false,
          reason: 'resolved private IP must be rejected',
        );
        expect(
          await reaches(ports.foreign, '127.0.0.1'),
          true,
          reason: 'foreign inbound must be untouched',
        );
        expect(
          await udpReaches(ports.owned),
          false,
          reason: 'private UDP must be rejected',
        );
        expect(
          await udpReaches(ports.foreign),
          true,
          reason: 'foreign UDP must be untouched',
        );
        ports = await start({
          'accessRules':
              '[{"type":"domain","target":"blocked.test","action":"block"}]',
          'dnsMode': 'custom',
          'resolvers': 'https://dns.google/dns-query\ntls://one.one.one.one',
        });
        expect(await reaches(ports.owned, 'blocked.test'), false);
        expect(await reaches(ports.owned, '127.0.0.1'), true);
        ports = await start({'blockPrivate': 'false', 'dnsMode': 'existing'});
        expect(
          await reaches(ports.owned, 'blocked.test'),
          true,
          reason: 'disabling policy must restore direct traffic',
        );
      } finally {
        if (process != null) {
          process!.kill();
          await process!.exitCode;
        }
        await target.close(force: true);
        udpTarget.close();
        await directory.delete(recursive: true);
      }
    },
    skip: binary == null
        ? 'Set SKY_UI_MIHOMO_BINARY to the verified mihomo binary.'
        : false,
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
