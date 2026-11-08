import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/engines/proxy/configuration.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import 'protocol_matrix.dart' show MatrixSupervisor;

Future<int> freePort() async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final port = 20000 + Random.secure().nextInt(24000);
    ServerSocket? tcp;
    RawDatagramSocket? udp;
    try {
      tcp = await ServerSocket.bind('127.0.0.1', port);
      udp = await RawDatagramSocket.bind(
        '127.0.0.1',
        port,
        reuseAddress: false,
        reusePort: false,
      );
      return port;
    } on SocketException {
      continue;
    } finally {
      udp?.close();
      await tcp?.close();
    }
  }
  throw StateError('No isolated test port available');
}

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    throw ArgumentError(
      'Usage: relink_contract.dart <fixture-dir> <mihomo> <sing-box> <xray>',
    );
  }
  final directory = Directory(args[0]).absolute;
  if (!directory.path.contains('relink-protocol')) {
    throw ArgumentError(
      'Use an explicitly named relink-protocol fixture directory.',
    );
  }
  await directory.create(recursive: true);
  final certificate = await File('${directory.path}/cert.pem').readAsString();
  final privateKey = await File('${directory.path}/key.pem').readAsString();
  final targetPort = await freePort();
  final cases = <Map<String, Object?>>[];
  for (final (coreId, binary) in [
    ('mihomo', args[1]),
    ('sing-box', args[2]),
    ('xray', args[3]),
  ]) {
    final core = ManagedCore(
      id: 'primary',
      coreId: coreId,
      service: 'fixture-only.service',
      binary: File(binary).absolute.path,
      directory: directory.path,
      configuration: '${directory.path}/unused.json',
      controller: Uri.parse('http://127.0.0.1:19099'),
      secret: 'fixture-only',
    );
    final supervisor = MatrixSupervisor();
    final ConfigurationCodec codec = coreId == 'mihomo'
        ? MihomoConfiguration(
            supervisor: supervisor,
            core: core,
            publicAddress: 'localhost',
          )
        : ProxyConfiguration(coreId, supervisor: supervisor, core: core);
    for (final definition in codec.protocols.where(
      (definition) => productProtocol(definition.id) != null,
    )) {
      final variants = <Map<String, String>>[];
      final transports = definition.fields
          .firstWhere((field) => field.id == 'transport')
          .options;
      final securities = definition.fields
          .firstWhere((field) => field.id == 'security')
          .options;
      for (final transport in transports) {
        for (final security in securities) {
          final defaults = definition.defaults({
            'transport': transport,
            'security': security,
          });
          if (defaults['transport'] == transport &&
              defaults['security'] == security) {
            variants.add({'transport': transport, 'security': security});
          }
        }
      }
      if (definition.id == 'hysteria2') {
        for (final obfs
            in coreId == 'mihomo' ? ['salamander', 'gecko'] : ['salamander']) {
          variants.add({coreId == 'mihomo' ? 'native.obfs' : 'obfs': obfs});
        }
      }
      if (definition.id == 'shadowsocks') {
        final key = coreId == 'mihomo' ? 'native.cipher' : 'cipher';
        for (final cipher
            in definition.fields
                .firstWhere((field) => field.id == key)
                .options) {
          variants.add({key: cipher});
        }
      }
      if (definition.id == 'vless' && coreId == 'xray') {
        for (final mode in ['packet-up', 'stream-up', 'stream-one']) {
          variants.add({
            'transport': 'XHTTP',
            'security': 'TLS',
            'xhttpMode': mode,
          });
        }
      }
      for (final (index, variant) in variants.indexed) {
        final port = await freePort();
        final id = '$coreId-${definition.id}-$index';
        final values = definition.defaults({
          'listen': '127.0.0.1',
          'serverName': definition.id == 'naive'
              ? 'naive-fixture.test'
              : 'localhost',
          'certificateSource': 'custom',
          'tlsCertificate': certificate,
          'tlsPrivateKey': privateKey,
          'native.target': '127.0.0.1:$targetPort',
          'realityTarget': '127.0.0.1:$targetPort',
          'handshakePort': '$targetPort',
          ...variant,
        });
        final input = Connection(
          id: id,
          name: id,
          coreId: coreId,
          protocolId: definition.id,
          port: port,
          settings: {
            for (final field in definition.activeFields(values))
              field.id: values[field.id] ?? '',
          },
        );
        final normalized = codec.validateSettings(input);
        final secrets = await codec.connectionSecrets(
          Connection(
            id: id,
            name: id,
            coreId: coreId,
            protocolId: definition.id,
            port: port,
            settings: normalized,
          ),
          previous: {
            for (final field in definition.fields.where(
              (field) => field.secret,
            ))
              if (normalized[field.id]?.isNotEmpty == true)
                'field:${field.id}': normalized[field.id]!,
          },
        );
        final secretFields = definition.fields
            .where((field) => field.secret)
            .map((field) => field.id)
            .toSet();
        final connection = StoredConnection(
          Connection(
            id: id,
            name: id,
            coreId: coreId,
            protocolId: definition.id,
            port: port,
            shareable: definition.shareable,
            settings: Map<String, String>.from(normalized)
              ..removeWhere((key, _) => secretFields.contains(key)),
          ),
          secrets,
        );
        final credentials = await codec.grantCredentials(connection);
        if (definition.isolatedBindings) credentials['port'] = '$port';
        final grant = AccessGrant(
          id: 'grant-$id',
          recipientId: 'fixture',
          connectionId: id,
          credentials: credentials,
        );
        final data = PanelData(
          serverName: 'Isolated Relink contract',
          address: '127.0.0.1',
          connections: [connection],
          recipients: [
            const StoredRecipient(
              id: 'fixture',
              name: 'Fixture',
              enabled: true,
              token: 'not-a-subscription',
            ),
          ],
          grants: [grant],
        );
        final previous = coreId == 'mihomo'
            ? '{"mode":"rule","log-level":"warning","ipv6":false,"rules":["MATCH,DIRECT"],"listeners":[]}'
            : coreId == 'sing-box'
            ? '{"log":{"level":"warn"},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}]}'
            // Only the isolated echo fixture may reach loopback. Xray blocks
            // private targets by default; production policy stays unchanged.
            : '{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct","settings":{"finalRules":[{"action":"allow","ip":["127.0.0.1/32"]}]}}]}';
        final server = codec.compile(data, core, previous);
        final endpoint = codec.clientEndpoint(connection, grant, '127.0.0.1');
        final serverFile = '${directory.path}/$id-server.json';
        await File(serverFile).writeAsString(server);
        final profile = {
          'id': id,
          'name': id,
          'protocol': endpoint.protocolId,
          'server': endpoint.server,
          'port': endpoint.port,
          'settings': endpoint.settings,
          'credentials': endpoint.credentials,
        };
        final expected = endpoint.protocolId == 'naive'
            ? null
            : (jsonDecode(ClashExporter().profile([endpoint]))
                  as Map)['proxies'][0];
        cases.add({
          'id': id,
          'core': coreId,
          'binary': core.binary,
          'serverFile': serverFile,
          'profile': profile,
          if (expected != null) 'expectedMihomo': expected,
        });
      }
    }
  }
  await File('${directory.path}/contract.json').writeAsString(
    jsonEncode({
      'version': 1,
      'realityTargetPort': targetPort,
      'certificate': certificate,
      'privateKeyFile': '${directory.path}/key.pem',
      'cases': cases,
    }),
  );
  stdout.writeln('Generated ${cases.length} real Sky UI codec cases.');
}
