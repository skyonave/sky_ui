import 'dart:convert';
import 'dart:io';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/application/contracts/connection_diagnostics.dart';
import 'package:sky_ui_api/src/engines/amnezia/configuration.dart';
import 'package:sky_ui_api/src/engines/proxy/configuration.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';
import 'core_manager_test.dart' show FakeSupervisor, fixtureCore;

void main() {
  late Directory work;
  setUp(() async {
    work = await Directory.systemTemp.createTemp('sky-ui-diagnostic-plans-');
    await File('${work.path}/index.json').writeAsString(
      jsonEncode({
        'panel': {
          'host': 'vpn.example.com',
          'expiresAt': DateTime.now()
              .add(const Duration(days: 30))
              .toIso8601String(),
        },
      }),
    );
  });
  tearDown(() async {
    if (work.absolute.parent.uri != Directory.systemTemp.absolute.uri)
      throw StateError('Unexpected fixture directory');
    await work.delete(recursive: true);
  });
  ConnectionDiagnosticPlan plan(
    ConfigurationCodec codec,
    String protocol, {
    Map<String, String> settings = const {},
    bool grant = true,
    List<AccessGrant>? grants,
    List<StoredRecipient>? recipients,
  }) {
    final definition = codec.protocols.singleWhere((p) => p.id == protocol);
    final defaults = definition.defaults(settings);
    final values = {
      for (final field in definition.activeFields(defaults))
        field.id: defaults[field.id] ?? field.initialValue(defaults),
    };
    final value = Connection(
      id: 'c_fixture',
      name: 'fixture',
      coreId: codec.coreId,
      protocolId: protocol,
      port: 35001,
      settings: codec.validateSettings(
        Connection(
          id: 'c_fixture',
          name: 'fixture',
          coreId: codec.coreId,
          protocolId: protocol,
          port: 35001,
          settings: values,
        ),
      ),
    );
    final connection = StoredConnection(value, const {});
    final data = PanelData(
      serverName: 'fixture',
      address: 'vpn.example.com',
      connections: [connection],
      recipients:
          recipients ??
          [
            const StoredRecipient(
              id: 'u_fixture',
              name: 'Friend',
              enabled: true,
              token: 'fixture-token',
            ),
          ],
      grants:
          grants ??
          [
            if (grant)
              const AccessGrant(
                id: 'g_fixture',
                recipientId: 'u_fixture',
                connectionId: 'c_fixture',
                credentials: {},
              ),
          ],
    );
    return (codec as ConnectionDiagnosticsCodec).diagnosticPlan(
      data,
      connection,
    );
  }

  ProxyConfiguration jsonCodec(String id) => ProxyConfiguration(
    id,
    supervisor: FakeSupervisor(),
    core: fixtureCore(),
    certificatesDirectory: work.path,
  );
  test('Xray keeps handshake destination separate from SNI', () {
    final result = plan(
      jsonCodec('xray'),
      'vless',
      settings: {
        'security': 'REALITY',
        'realityTarget': 'target.example:10443',
        'serverName': 'sni.example',
      },
    );
    expect(result.tls!.host, 'target.example');
    expect(result.tls!.port, 10443);
    expect(result.tls!.serverName, 'sni.example');
    expect(result.tls!.tls13, isTrue);
    expect(result.listeners.map((l) => (l.port, l.udp)), [(35001, false)]);
  });
  test(
    'mihomo uses its own handshake port and all active isolated sockets',
    () {
      final codec = MihomoConfiguration(certificatesDirectory: work.path);
      final reality = plan(
        codec,
        'vless',
        settings: {
          'security': 'REALITY',
          'serverName': 'sni.example',
          'handshakePort': '10443',
        },
      );
      expect(reality.tls!.host, 'sni.example');
      expect(reality.tls!.port, 10443);
      final ss = plan(
        codec,
        'shadowsocks',
        grants: [
          const AccessGrant(
            id: 'g1',
            recipientId: 'u_fixture',
            connectionId: 'c_fixture',
            credentials: {'port': '35002'},
          ),
          const AccessGrant(
            id: 'g2',
            recipientId: 'u2',
            connectionId: 'c_fixture',
            credentials: {'port': '35003'},
          ),
          const AccessGrant(
            id: 'g3',
            recipientId: 'off',
            connectionId: 'c_fixture',
            credentials: {'port': '35004'},
          ),
        ],
        recipients: [
          const StoredRecipient(
            id: 'u_fixture',
            name: 'One',
            enabled: true,
            token: 'one',
          ),
          const StoredRecipient(
            id: 'u2',
            name: 'Two',
            enabled: true,
            token: 'two',
          ),
          const StoredRecipient(
            id: 'off',
            name: 'Off',
            enabled: false,
            token: 'off',
          ),
        ],
      );
      expect(ss.listeners.map((l) => (l.port, l.udp)).toSet(), {
        (35002, false),
        (35002, true),
        (35003, false),
        (35003, true),
      });
    },
  );
  test(
    'unassigned proxy has no socket, while REALITY target remains diagnosable',
    () {
      final result = plan(jsonCodec('xray'), 'vless', grant: false);
      expect(result.listeners, isEmpty);
      expect(result.tls, isNotNull);
    },
  );
  test('native QUIC protocols never produce a fake TCP/TLS listener probe', () {
    final codec = MihomoConfiguration(certificatesDirectory: work.path);
    for (final id in ['hysteria2', 'tuic']) {
      final result = plan(
        codec,
        id,
        settings: {'certificateSource': 'panel', 'certificateId': 'panel'},
      );
      expect(result.listeners.every((l) => l.udp), isTrue, reason: id);
      expect(result.tls, isNull);
      expect(result.tlsSkipCode, 'quic_client_required');
    }
    final naive = plan(
      jsonCodec('sing-box'),
      'naive',
      settings: {
        'transport': 'HTTP/3',
        'certificateSource': 'panel',
        'certificateId': 'panel',
      },
    );
    expect(naive.listeners.single.udp, isTrue);
    expect(naive.tlsSkipCode, 'quic_client_required');
  });
  test(
    'plain TLS probes the actual local binding using the configured certificate name',
    () {
      final result = plan(
        jsonCodec('sing-box'),
        'naive',
        settings: {
          'transport': 'HTTP/2',
          'certificateSource': 'panel',
          'certificateId': 'panel',
          'serverName': 'vpn.example.com',
        },
      );
      expect(result.tls!.remote, isFalse);
      expect(result.tls!.host, '::1');
      expect(result.tls!.port, result.listeners.single.port);
      expect(result.tls!.serverName, 'vpn.example.com');
    },
  );
  test('AWG declares its UDP socket and managed interface rather than TLS', () {
    final result = plan(AmneziaConfiguration(), 'amneziawg');
    expect(result.listeners.single.udp, isTrue);
    expect(
      result.listeners.single.interfaceName,
      AmneziaConfiguration.interfaceName('c_fixture'),
    );
    expect(result.tls, isNull);
    expect(result.tlsSkipCode, 'awg_client_required');
  });
  test(
    'mihomo can diagnose stored TLS after its certificate is removed',
    () async {
      final codec = MihomoConfiguration(certificatesDirectory: work.path);
      final connection = StoredConnection(
        const Connection(
          id: 'stored',
          name: 'Stored TLS',
          coreId: 'mihomo',
          protocolId: 'vless',
          port: 35001,
          settings: {
            'listen': '::',
            'transport': 'TCP',
            'security': 'TLS',
            'certificateSource': 'panel',
            'certificateId': 'panel',
            'serverName': 'vpn.example.com',
          },
        ),
        const {},
      );
      await File('${work.path}/index.json').writeAsString('{}');
      final data = PanelData(
        serverName: 'fixture',
        address: 'vpn.example.com',
        connections: [connection],
        recipients: [
          const StoredRecipient(
            id: 'u',
            name: 'Friend',
            enabled: true,
            token: 'fixture',
          ),
        ],
        grants: [
          const AccessGrant(
            id: 'g',
            recipientId: 'u',
            connectionId: 'stored',
            credentials: {},
          ),
        ],
      );
      final result = codec.diagnosticPlan(data, connection);
      expect(result.listeners.single.port, 35001);
      expect(result.tls!.host, '::1');
      expect(result.tls!.serverName, 'vpn.example.com');
      expect(
        () => codec.validateSettings(connection.value),
        throwsA(isA<ApiException>()),
      );
    },
  );
}
