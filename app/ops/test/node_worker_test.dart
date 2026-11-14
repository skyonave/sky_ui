import 'package:sky_ui_ops/src/features/servers/node_worker.dart';
import 'package:sky_ui_ops/src/platform/host.dart';
import 'package:test/test.dart';

void main() {
  test(
    'retained active ingress determines independent reinstallation startup',
    () {
      expect(
        nodeConfigurationBindings('amneziawg', {
          'interfaces': [
            {'port': 35001, 'peers': []},
          ],
        }).udp,
        {35001},
      );
      expect(
        nodeConfigurationBindings('amneziawg', {
          'interfaces': [
            {
              'port': 35001,
              'peers': [{}],
            },
          ],
        }).udp,
        {35001},
      );
      expect(
        nodeConfigurationBindings('sing-box', {
          'inbounds': [
            {'type': 'naive', 'listen_port': 35002, 'network': 'udp'},
          ],
        }).udp,
        {35002},
      );
      expect(
        nodeConfigurationBindings('mihomo', {
          'listeners': [
            {'type': 'shadowsocks', 'port': 35003},
          ],
        }).tcp,
        {35003},
      );
      expect(
        nodeConfigurationBindings('mihomo', {
          'listeners': [
            {'type': 'shadowsocks', 'port': 35003},
          ],
        }).udp,
        {35003},
      );
      expect(
        nodeConfigurationBindings('xray', {
          'inbounds': [
            {'protocol': 'vless', 'port': 35004},
            {'protocol': 'dokodemo-door', 'port': 1000},
          ],
        }).tcp,
        {35004},
      );
    },
  );
  test('native network selection matches UDP-only and dual listeners', () {
    final actual = nodeConfigurationBindings('mihomo', {
      'listeners': [
        {
          'type': 'trusttunnel',
          'port': 35001,
          'network': ['udp'],
        },
        {
          'type': 'trusttunnel',
          'port': 35002,
          'network': ['tcp', 'udp'],
        },
        {'type': 'shadowsocks', 'port': 35003, 'udp': false},
        {'type': 'tuic-v4', 'port': 35004},
        {'type': 'shadowquic', 'port': 35005},
      ],
    });
    expect(actual.tcp, {35002, 35003});
    expect(actual.udp, {35001, 35002, 35004, 35005});
    final sing = nodeConfigurationBindings('sing-box', {
      'inbounds': [
        {'type': 'shadowsocks', 'listen_port': 35006, 'network': 'udp'},
      ],
    });
    expect(sing.tcp, isEmpty);
    expect(sing.udp, {35006});
    final xray = nodeConfigurationBindings('xray', {
      'inbounds': [
        {
          'protocol': 'shadowsocks',
          'port': 35007,
          'settings': {'network': 'tcp'},
        },
      ],
    });
    expect(xray.tcp, {35007});
    expect(xray.udp, isEmpty);
  });
  test('forced node commands accept only fixed engine and operation names', () {
    expect(parseNodeCommand(['inventory']).verb, 'inventory');
    expect(parseNodeCommand(['ports']).verb, 'ports');
    for (final engine in nodeEngines) {
      for (final verb in nodeVerbs)
        expect(parseNodeCommand([verb, engine]).engine, engine);
    }
    for (final input in <List<String>>[
      [],
      ['install'],
      ['install', 'other'],
      ['start', 'xray; id'],
      ['sh', '-c'],
      ['logs', 'mihomo', '--follow'],
      ['inventory', 'xray'],
    ]) {
      expect(() => parseNodeCommand(input), throwsA(isA<OpsError>()));
    }
  });
  test(
    'node deployment port claims reject reserved, malformed and oversized sets',
    () {
      expect(nodePorts([35001, 35001, 65535]), {35001, 65535});
      for (final value in [
        null,
        {},
        [22],
        [65536],
        ['35001'],
        List.filled(4097, 35001),
      ])
        expect(() => nodePorts(value), throwsA(isA<OpsError>()));
    },
  );
}
