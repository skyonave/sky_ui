import 'dart:convert';
import 'dart:io';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/engines/proxy/configuration.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';
import 'core_manager_test.dart' show FakeSupervisor;

void main() {
  late Directory work;
  setUp(() async {
    work = await Directory.systemTemp.createTemp('sky-ui-settings-');
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
  tearDown(() => work.delete(recursive: true));
  ProxyConfiguration codec(String id) => ProxyConfiguration(
    id,
    certificatesDirectory: work.path,
    supervisor: FakeSupervisor(),
    core: ManagedCore(
      id: id,
      coreId: id,
      service: 'fixture',
      binary: '/unused',
      directory: work.path,
      configuration: '${work.path}/config.json',
      controller: Uri.parse('http://127.0.0.1:0'),
      secret: '',
    ),
  );
  Connection input(
    String core,
    String protocol,
    Map<String, String> settings,
  ) => Connection(
    id: 'c',
    name: 'fixture',
    coreId: core,
    instanceId: core,
    protocolId: protocol,
    port: 31001,
    settings: settings,
  );
  Future<({Map native, ClientEndpoint endpoint})> compile(
    String core,
    String protocol,
    Map<String, String> settings,
  ) async {
    final c = codec(core);
    final values = c.validateSettings(input(core, protocol, settings));
    final value = input(core, protocol, values);
    final stored = StoredConnection(value, await c.connectionSecrets(value));
    final grant = AccessGrant(
      id: 'g',
      recipientId: 'u',
      connectionId: 'c',
      credentials: await c.grantCredentials(stored),
    );
    final data = PanelData(
      serverName: 'test',
      address: 'vpn.example.com',
      connections: [stored],
      grants: [grant],
      recipients: [
        const StoredRecipient(
          id: 'u',
          name: 'test',
          enabled: true,
          token: 'fixture',
        ),
      ],
    );
    return (
      native: jsonDecode(c.compile(data, c.core, '')) as Map,
      endpoint: c.clientEndpoint(stored, grant, 'vpn.example.com'),
    );
  }

  final tls = {
    'security': 'TLS',
    'certificateSource': 'panel',
    'certificateId': 'panel',
  };
  test(
    'TLS bounds and ALPN reach both native engines and client exports',
    () async {
      for (final core in ['xray', 'sing-box']) {
        final result = await compile(core, 'vless', {
          ...tls,
          'tlsMinVersion': '1.3',
          'tlsMaxVersion': '1.3',
          'clientAlpn': 'h2\nhttp/1.1',
        });
        final inbound = (result.native['inbounds'] as List).single as Map;
        final nativeTls = core == 'xray'
            ? inbound['streamSettings']['tlsSettings'] as Map
            : inbound['tls'] as Map;
        expect(nativeTls[core == 'xray' ? 'minVersion' : 'min_version'], '1.3');
        expect(nativeTls[core == 'xray' ? 'maxVersion' : 'max_version'], '1.3');
        expect(nativeTls['alpn'], ['h2', 'http/1.1']);
        final uri = Uri.parse(
          ShareUriCodec().links([result.endpoint]).single.uri,
        );
        expect(uri.queryParameters['alpn'], 'h2,http/1.1');
        expect(
          ClashExporter().profile([result.endpoint]),
          contains('http/1.1'),
        );
      }
    },
  );
  test(
    'WebSocket Host reaches Xray verification and both client formats',
    () async {
      for (final core in ['xray', 'sing-box']) {
        final result = await compile(core, 'vless', {
          ...tls,
          'transport': 'WebSocket',
          'websocketHost': 'front.example.com',
          'clientAlpn': 'http/1.1',
        });
        if (core == 'xray')
          expect(
            result
                .native['inbounds'][0]['streamSettings']['wsSettings']['host'],
            'front.example.com',
          );
        expect(
          Uri.parse(
            ShareUriCodec().links([result.endpoint]).single.uri,
          ).queryParameters['host'],
          'front.example.com',
        );
        final profile =
            jsonDecode(ClashExporter().profile([result.endpoint])) as Map;
        expect(
          profile['proxies'][0]['ws-opts']['headers']['Host'],
          'front.example.com',
        );
      }
    },
  );
  test(
    'REALITY clock tolerance uses engine-specific units without exporting server controls',
    () async {
      for (final core in ['xray', 'sing-box']) {
        final result = await compile(core, 'vless', {
          'realityMaxTimeDiff': '60',
        });
        final reality = core == 'xray'
            ? result.native['inbounds'][0]['streamSettings']['realitySettings']
                  as Map
            : result.native['inbounds'][0]['tls']['reality'] as Map;
        expect(
          reality[core == 'xray' ? 'maxTimeDiff' : 'max_time_difference'],
          core == 'xray' ? 60000 : '60s',
        );
        expect(
          result.endpoint.settings.containsKey('realityMaxTimeDiff'),
          false,
        );
        expect(result.endpoint.credentials.containsKey('privateKey'), false);
      }
    },
  );
  test(
    'incompatible TLS/ALPN, invalid Host and unsupported fingerprints are rejected',
    () {
      for (final values in [
        {...tls, 'tlsMinVersion': '1.3', 'tlsMaxVersion': '1.2'},
        {...tls, 'transport': 'WebSocket', 'clientAlpn': 'h2'},
        {...tls, 'transport': 'gRPC', 'clientAlpn': 'http/1.1'},
        {...tls, 'transport': 'WebSocket', 'websocketHost': 'bad.example/path'},
        {'clientFingerprint': 'invented'},
      ]) {
        expect(
          () => codec('xray').validateSettings(input('xray', 'vless', values)),
          throwsA(isA<ApiException>()),
        );
      }
    },
  );
  test(
    'non-VLESS controls reach their protocol and do not leak into client requirements',
    () async {
      final tuic = await compile('sing-box', 'tuic', {
        ...tls,
        'tuicAuthTimeout': '5',
        'tuicHeartbeat': '20',
        'udpTimeout': '180',
      });
      expect(tuic.native['inbounds'][0]['auth_timeout'], '5s');
      expect(tuic.native['inbounds'][0]['heartbeat'], '20s');
      expect(tuic.native['inbounds'][0]['udp_timeout'], '180s');
      final naive = await compile('sing-box', 'naive', {
        ...tls,
        'transport': 'HTTP/3',
        'naiveCongestionControl': 'cubic',
      });
      expect(naive.native['inbounds'][0]['quic_congestion_control'], 'cubic');
      final hysteria = await compile('sing-box', 'hysteria2', {
        ...tls,
        'hysteriaMasquerade': 'https://www.example.com/',
      });
      expect(
        hysteria.native['inbounds'][0]['masquerade'],
        'https://www.example.com/',
      );
      expect(
        hysteria.endpoint.settings.containsKey('hysteriaMasquerade'),
        false,
      );
      final ss = await compile('sing-box', 'shadowsocks', {
        'udpTimeout': '120',
      });
      expect(ss.native['inbounds'][0]['udp_timeout'], '120s');
    },
  );
}
