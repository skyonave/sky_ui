import 'dart:io';
import 'package:sky_ui_api/src/application/connections/field_generators.dart';
import 'package:sky_ui_api/src/application/subscriptions/client_exporter.dart';
import 'package:sky_ui_api/src/application/access/records.dart';
import 'package:sky_ui_api/src/engines/amnezia/configuration.dart';
import 'package:test/test.dart';

void main() {
  test('new AWG drafts keep handshake overload protection enabled', () {
    final schema = AmneziaConfiguration().protocols.single;
    expect(schema.defaults({})['awg.DisableCookies'], 'false');
    expect(
      schema.defaults({'awg.DisableCookies': 'true'})['awg.DisableCookies'],
      'true',
    );
  });
  test('Linux rejects occupied TCP/UDP sockets', () async {
    final tcp = await ServerSocket.bind('127.0.0.1', 0);
    final udp = await RawDatagramSocket.bind(
      '127.0.0.1',
      0,
      reuseAddress: false,
    );
    try {
      expect(await connectionPortAvailable(tcp.port), isFalse);
      expect(await connectionPortAvailable(udp.port), isFalse);
    } finally {
      await tcp.close();
      udp.close();
    }
  }, skip: !Platform.isLinux);
  test('allocator excludes stored ports and unsuccessful OS probes', () async {
    final candidates = [22222, 22223, 22224, 33445].iterator;
    final port = await randomConnectionPort(
      {22222},
      next: () {
        candidates.moveNext();
        return candidates.current;
      },
      probe: (port) async => port == 33445,
    );
    expect(port, 33445);
  });
  test(
    'AWG generators keep packet lengths, header identities and junk sizes coherent',
    () {
      for (var attempt = 0; attempt < 40; attempt++) {
        final values = <String, String>{};
        for (var i = 1; i <= 4; i++) {
          values.addAll(
            generateConnectionValue('awg.H$i', 'awg-header', values),
          );
        }
        expect(values.values.toSet(), hasLength(4));
        values.addAll(generateConnectionValue('awg.S1', 'awg-padding', values));
        expect(
          int.parse(values['awg.S1']!) + 148,
          isNot(int.parse(values['awg.S2']!) + 92),
        );
        values.addAll(
          generateConnectionValue('awg.Jmin', 'awg-junk-size', values),
        );
        expect(
          int.parse(values['awg.Jmax']!),
          greaterThan(int.parse(values['awg.Jmin']!)),
        );
      }
    },
  );
  ClientEndpoint endpoint(String protocol) => ClientEndpoint(
    id: protocol,
    name: protocol,
    server: 'example.com',
    port: 21000,
    protocolId: protocol,
    settings: {
      'transport': 'TCP',
      'security': 'REALITY',
      'protocolOptions': '{}',
    },
    credentials: {
      'uuid': 'test',
      'publicKey': 'test',
      'shortId': 'abc',
      'password': 'test',
    },
  );
  test(
    'a mixed subscription retains compatible entries instead of rejecting all',
    () {
      final values = [
        endpoint('vless'),
        endpoint('mieru'),
        endpoint('trusttunnel'),
        endpoint('naive'),
      ];
      final selected = exportableEndpoints(
        V2RayExporter(),
        values,
        client: 'v2box',
      );
      expect(selected.map((e) => e.protocolId), ['vless']);
      expect(V2RayExporter().canExport(values), isFalse);
      expect(V2RayExporter().profile(selected), isNotEmpty);
      expect(subscriptionClientFor('V2Box/11.0 CFNetwork'), 'v2box');
    },
  );
}
