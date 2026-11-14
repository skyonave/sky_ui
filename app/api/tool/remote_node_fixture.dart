import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/application/configuration/relay_routes.dart';
import 'package:sky_ui_api/src/engines/amnezia/configuration.dart';
import 'package:sky_ui_api/src/engines/proxy/configuration.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

class FixtureTransport implements EngineRelayTransport {
  @override
  Map<String, ServerNode> nodes() => const {
    'node': ServerNode(
      id: 'node',
      name: 'Fixture',
      host: '192.0.2.10',
      port: 22,
      publicKey: '',
    ),
  };
  @override
  Future<RelayState> inspectEngine(String node, String engine) async =>
      RelayState(
        digest(switch (engine) {
          'mihomo' => '{"mode":"rule","log-level":"info","listeners":[]}\n',
          'amneziawg' => '{"version":"3.1","interfaces":[]}\n',
          _ => '{}\n',
        }),
        false,
        extendedUdp: true,
      );
  @override
  Future<void> validateEngine(
    String node,
    String engine,
    String configuration,
  ) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FixtureSupervisor implements ProcessSupervisor {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> main(List<String> args) async {
  if (args.length != 1) throw ArgumentError('Output directory required');
  final output = Directory(args.single)..createSync(recursive: true);
  final cores = {
    for (final id in ['mihomo', 'sing-box', 'xray', 'amneziawg'])
      id: ManagedCore(
        id: id == 'mihomo' ? 'primary' : id,
        coreId: id,
        service: 'fixture',
        binary: '',
        directory: '',
        configuration: '',
        controller: Uri.parse('http://127.0.0.1:19090'),
        secret: '',
      ),
  };
  final codecs = <String, ConfigurationCodec>{
    'mihomo': MihomoConfiguration(),
    'amneziawg': AmneziaConfiguration(),
    for (final id in ['sing-box', 'xray'])
      id: ProxyConfiguration(
        id,
        core: cores[id]!,
        supervisor: FixtureSupervisor(),
      ),
  };
  final before = PanelData(serverName: 'Fixture', address: '192.0.2.10'),
      after = before.copy();
  after.recipients.add(
    const StoredRecipient(
      id: 'user',
      name: 'Fixture',
      enabled: true,
      token: 'fixture',
    ),
  );
  for (final (index, entry) in codecs.entries.indexed) {
    final id = entry.key, codec = entry.value;
    final draft = Connection(
      id: 'c_fixture_$index',
      name: 'Fixture $id',
      coreId: id,
      instanceId: cores[id]!.id,
      protocolId: id == 'amneziawg' ? 'amneziawg' : 'vless',
      port: 35300 + index,
      route: const ['node'],
      settings: id == 'amneziawg'
          ? const {}
          : const {'security': 'REALITY', 'serverName': 'www.kernel.org'},
    );
    final value = Connection.fromJson({
      ...draft.toJson(),
      'settings': codec.validateSettings(draft),
    });
    final record = StoredConnection(
      value,
      await codec.connectionSecrets(value),
    );
    after.connections.add(record);
    final credentials = await codec.grantCredentials(record);
    after.grants.add(
      AccessGrant(
        id: 'g_fixture_$index',
        recipientId: 'user',
        connectionId: value.id,
        credentials: codec is GrantAllocator
            ? (codec as GrantAllocator).allocateGrant(
                after,
                record,
                credentials,
              )
            : credentials,
      ),
    );
  }
  final changes = await RelayRoutes(FixtureTransport(), allowNew: true).changes(
    before,
    after,
    codecs['mihomo']!,
    cores['mihomo']!,
    codecs: codecs,
    cores: cores.values,
  );
  for (final change in changes) {
    File(
      '${output.path}/${change.engine}.json',
    ).writeAsStringSync(change.configuration);
    File('${output.path}/${change.engine}.deploy.json').writeAsStringSync(
      jsonEncode({
        'transaction': 'tx_ABCDEFGHIJKLMNOPQRSTUV',
        'previous': change.previous,
        'configuration': change.configuration,
        'tcp': change.ports.toList(),
        'udp': change.udpPorts.toList(),
      }),
    );
  }
  stdout.writeln('Prepared ${changes.length} remote engine fixtures.');
}
