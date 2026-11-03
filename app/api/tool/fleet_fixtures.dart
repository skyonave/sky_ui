import 'dart:convert';
import 'dart:io';
import 'package:sky_ui_api/src/bootstrap/server_config.dart';
import 'package:sky_ui_api/src/engines/contracts.dart';
import 'package:sky_ui_api/src/engines/mihomo/configuration.dart';
import 'package:sky_ui_api/src/engines/amnezia/configuration.dart';
import 'package:sky_ui_api/src/application/contracts/configuration_codec.dart';
import 'package:sky_ui_api/src/application/access/records.dart';
import 'package:sky_ui_api/src/application/subscriptions/client_exporter.dart';
import 'package:sky_ui_api/src/engines/proxy/configuration.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

class FixtureSupervisor implements ProcessSupervisor {
  @override
  bool get supported => true;
  @override
  Future<ServiceObservation> inspect(ManagedCore core) async =>
      const ServiceObservation(CoreProcessState.inactive);
  @override
  Future<void> execute(ManagedCore core, CoreOperation operation) async =>
      throw StateError('No live services in fixture generation.');
}

Future<void> main(List<String> args) async {
  final root = Directory(args.single).absolute;
  if (!root.path.contains('protocol-first'))
    throw ArgumentError('Use a private protocol-first fixture directory.');
  await root.create(recursive: true);
  final certificate = await File('${root.path}/cert.pem').readAsString(),
      privateKey = await File('${root.path}/key.pem').readAsString();
  final results = <Map<String, Object?>>[];
  final cases = <(String, String, String, Map<String, String>)>[
    for (final engine in ['xray', 'sing-box']) ...[
      (engine, 'vless', 'reality', {'transport': 'TCP', 'security': 'REALITY'}),
      for (final transport in [
        'TCP',
        'WebSocket',
        'gRPC',
        if (engine == 'xray') 'XHTTP',
      ])
        (
          engine,
          'vless',
          transport.toLowerCase(),
          {'transport': transport, 'security': 'TLS'},
        ),
      (engine, 'shadowsocks', 'basic', {}),
    ],
    (
      'xray',
      'vless',
      'xhttp-reality',
      {'transport': 'XHTTP', 'security': 'REALITY'},
    ),
    ('sing-box', 'hysteria2', 'tls', {}),
    (
      'sing-box',
      'hysteria2',
      'salamander',
      {'obfs': 'salamander', 'obfsPassword': 'fixture-obfuscation-password'},
    ),
    ('sing-box', 'tuic', 'v5', {}),
    ('sing-box', 'naive', 'h2', {'transport': 'HTTP/2'}),
    ('sing-box', 'naive', 'h3', {'transport': 'HTTP/3'}),
    (
      'mihomo',
      'hysteria2',
      'gecko',
      {
        'native.obfs': 'gecko',
        'native.obfs-password': 'fixture-obfuscation-password',
      },
    ),
    ('mihomo', 'mieru', 'basic', {}),
    ('mihomo', 'trusttunnel', 'basic', {}),
    ('mihomo', 'tuic', 'v5', {}),
    ('amneziawg', 'amneziawg', '3.1', {}),
  ];
  var index = 0;
  for (final entry in cases) {
    final engine = entry.$1,
        protocol = entry.$2,
        label = '$engine-$protocol-${entry.$3}';
    final core = ManagedCore(
      id: engine,
      coreId: engine,
      service: 'fixture-only.service',
      binary: '${root.path}/$engine',
      directory: root.path,
      configuration: '${root.path}/$label.json',
      controller: Uri.parse('http://127.0.0.1:0'),
      secret: '',
    );
    final ConfigurationCodec codec = engine == 'mihomo'
        ? MihomoConfiguration(core: core, publicAddress: 'localhost')
        : engine == 'amneziawg'
        ? AmneziaConfiguration()
        : ProxyConfiguration(
            engine,
            core: core,
            supervisor: FixtureSupervisor(),
          );
    stdout.writeln('Generating $label');
    final definition = codec.protocols.firstWhere((d) => d.id == protocol);
    final encrypted = definition.fields.any((f) => f.id == 'serverName');
    final certificateRequired =
        definition.fields.any((f) => f.id == 'certificateSource') &&
        entry.$4['security'] != 'REALITY';
    final settings = codec.validateSettings(
      Connection(
        id: label,
        name: label,
        coreId: engine,
        instanceId: engine,
        protocolId: protocol,
        port: 35500 + index,
        settings: {
          if (engine != 'amneziawg') 'listen': '127.0.0.1',
          if (encrypted)
            'serverName': protocol == 'naive' ? '127.0.0.1' : 'localhost',
          if (certificateRequired) ...{
            'certificateSource': 'custom',
            'tlsCertificate': certificate,
            'tlsPrivateKey': privateKey,
          },
          ...entry.$4,
        },
      ),
    );
    final value = Connection(
      id: label,
      name: label,
      coreId: engine,
      instanceId: engine,
      protocolId: protocol,
      port: 35500 + index,
      settings: settings,
    );
    final record = StoredConnection(
      value,
      await codec.connectionSecrets(value),
    );
    var credentials = await codec.grantCredentials(record);
    if (codec is GrantAllocator)
      credentials = (codec as GrantAllocator).allocateGrant(
        PanelData(serverName: '', address: '', connections: [record]),
        record,
        credentials,
      );
    final grant = AccessGrant(
      id: 'grant-$index',
      recipientId: 'recipient-$index',
      connectionId: label,
      credentials: credentials,
    );
    final data = PanelData(
      serverName: 'fixture',
      address: '127.0.0.1',
      connections: [record],
      recipients: [
        StoredRecipient(
          id: 'recipient-$index',
          name: 'fixture',
          enabled: true,
          token: 'fixture-only',
        ),
      ],
      grants: [grant],
    );
    await File(core.configuration).writeAsString(
      codec.compile(
        data,
        core,
        engine == 'mihomo' ? '{"mode":"direct","listeners":[]}' : '{}',
      ),
    );
    final endpoint = codec.clientEndpoint(record, grant, '127.0.0.1');
    Map<String, dynamic> client;
    if (protocol == 'naive') {
      client = {
        'log': {'level': 'debug'},
        'inbounds': [
          {
            'type': 'socks',
            'tag': 'socks',
            'listen': '127.0.0.1',
            'listen_port': 39000 + index,
          },
        ],
        'outbounds': [
          {
            'type': 'naive',
            'server': '127.0.0.1',
            'server_port': value.port,
            'username': grant.credentials['username'],
            'password': grant.credentials['password'],
            'quic': entry.$3 == 'h3',
            'tls': {
              'enabled': true,
              'server_name': '127.0.0.1',
              'certificate_path': '${root.path}/cert.pem',
            },
          },
        ],
      };
    } else {
      client =
          jsonDecode(ClashExporter().profile([endpoint]))
              as Map<String, dynamic>;
      client['mixed-port'] = 39000 + index;
      client['bind-address'] = '127.0.0.1';
      client['log-level'] = 'debug';
      for (final proxy in client['proxies'] as List) {
        proxy['skip-cert-verify'] = true;
      }
    }
    final path = '${root.path}/$label-client.json';
    await File(path).writeAsString(jsonEncode(client));
    results.add({
      'id': label,
      'engine': engine,
      'protocol': protocol,
      'server': core.configuration,
      'client': path,
      'clientEngine': protocol == 'naive' ? 'sing-box' : 'mihomo',
    });
    index++;
  }
  await File('${root.path}/fixtures.json').writeAsString(jsonEncode(results));
  stdout.writeln(
    'Generated ${results.length} isolated server/client fixtures.',
  );
}
