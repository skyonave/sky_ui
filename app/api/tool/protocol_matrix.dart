import 'dart:convert';
import 'dart:io';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2)
    throw ArgumentError(
      'Usage: protocol_matrix.dart <mihomo> <isolated-fixture-directory>',
    );
  final directory = Directory(args[1]).absolute;
  if (!directory.path.contains('protocol-matrix'))
    throw ArgumentError(
      'Use an explicitly named protocol-matrix fixture directory.',
    );
  await directory.create(recursive: true);
  final cert = await File('${directory.path}/cert.pem').readAsString(),
      key = await File('${directory.path}/key.pem').readAsString();
  final core = ManagedCore(
    id: 'primary',
    coreId: 'mihomo',
    service: 'fixture-only.service',
    binary: File(args[0]).absolute.path,
    directory: directory.path,
    configuration: '${directory.path}/unused.yaml',
    controller: Uri.parse('http://127.0.0.1:19099'),
    secret: 'fixture-only',
  );
  final supervisor = MatrixSupervisor();
  final fixturePort = await freePort();
  final codec = MihomoConfiguration(
    supervisor: supervisor,
    core: core,
    publicAddress: 'localhost',
    networkAdministration: true,
  );
  const runner = NativeCommandRunner();
  const clientPrefix = '--client-binary=';
  final clientBinary =
      args
          .where((arg) => arg.startsWith(clientPrefix))
          .firstOrNull
          ?.substring(clientPrefix.length) ??
      core.binary;
  final results = <Map<String, Object?>>[];
  var index = 0;
  final cases =
      <
        ({
          ProtocolDefinition definition,
          String id,
          Map<String, String> overrides,
        })
      >[];
  for (final definition in codec.protocols) {
    final transports = definition.fields
        .firstWhere((f) => f.id == 'transport')
        .options;
    final securities = definition.fields
        .firstWhere((f) => f.id == 'security')
        .options;
    for (final transport
        in args.contains('--variants') ? transports : transports.take(1)) {
      for (final security
          in args.contains('--variants') ? securities : securities.take(1)) {
        final values = definition.defaults({
          'transport': transport,
          'security': security,
        });
        if (values['transport'] != transport || values['security'] != security)
          continue;
        final id = transport == transports.first && security == securities.first
            ? definition.id
            : '${definition.id}--$transport--$security'
                  .toLowerCase()
                  .replaceAll(RegExp(r'[^a-z0-9-]'), '-');
        cases.add((
          definition: definition,
          id: id,
          overrides: {'transport': transport, 'security': security},
        ));
      }
    }
  }
  if (args.contains('--extras')) {
    void extra(String protocol, String suffix, Map<String, String> overrides) =>
        cases.add((
          definition: codec.protocols.firstWhere((p) => p.id == protocol),
          id: '$protocol--$suffix',
          overrides: overrides,
        ));
    final shadowsocks = codec.protocols.firstWhere(
      (p) => p.id == 'shadowsocks',
    );
    for (final cipher
        in shadowsocks.fields
            .firstWhere((f) => f.id == 'native.cipher')
            .options)
      if (cipher.isNotEmpty)
        extra('shadowsocks', 'cipher-$cipher', {
          'native.cipher': cipher,
          if (cipher == 'dummy') 'security': 'JLS',
        });
    for (final cipher in [
      'auto',
      'aes-128-gcm',
      'chacha20-poly1305',
      'zero',
      'none',
    ])
      extra('vmess', 'cipher-$cipher', {'clientCipher': cipher});
    for (final version in ['1', '2', '3', '4', '5'])
      extra('snell', 'version-$version', {'native.version': version});
    extra('hysteria2', 'salamander', {'native.obfs': 'salamander'});
  }
  for (final testCase in cases) {
    final definition = testCase.definition;
    final defaults = definition.defaults({
      'listen': '127.0.0.1',
      'serverName': 'localhost',
      'tlsCertificate': cert,
      'tlsPrivateKey': key,
      'realmToken': 'fixture-realm-only',
      'native.target': '127.0.0.1:33444',
      ...testCase.overrides,
      if (args.contains('--listen') && definition.id == 'shadowquic')
        'native.jls-upstream.addr': '127.0.0.1:33444',
      if (args.contains('--listen') && definition.id == 'shadowquic')
        'native.jls-upstream.sni': 'localhost',
    });
    final input = Connection(
      id: 'fixture',
      name: definition.name,
      coreId: 'mihomo',
      protocolId: definition.id,
      port: definition.usesPort ? fixturePort : null,
      settings: {
        for (final f in definition.activeFields(defaults))
          f.id: defaults[f.id] ?? '',
      },
    );
    try {
      final normalized = codec.validateSettings(input);
      final secrets = await codec.connectionSecrets(
        Connection(
          id: input.id,
          name: input.name,
          coreId: input.coreId,
          protocolId: input.protocolId,
          port: input.port,
          settings: normalized,
        ),
      );
      final secretIds = definition.fields
          .where((f) => f.secret)
          .map((f) => f.id)
          .toSet();
      final connection = StoredConnection(
        Connection(
          id: input.id,
          name: input.name,
          coreId: input.coreId,
          protocolId: input.protocolId,
          port: input.port,
          shareable: definition.shareable,
          settings: Map.from(normalized)
            ..removeWhere((k, _) => secretIds.contains(k)),
        ),
        secrets,
      );
      final credentials = await codec.grantCredentials(connection);
      if (definition.isolatedBindings) credentials['port'] = '$fixturePort';
      final grant = AccessGrant(
        id: 'fixture-grant',
        recipientId: 'fixture-user',
        connectionId: input.id,
        credentials: credentials,
      );
      final data = PanelData(
        serverName: 'Protocol verification',
        address: '127.0.0.1',
        connections: [connection],
        recipients: [
          const StoredRecipient(
            id: 'fixture-user',
            name: 'Fixture only',
            enabled: true,
            token: 'fixture-not-a-live-subscription',
          ),
        ],
        grants: definition.shareable ? [grant] : [],
      );
      final candidate = codec.compile(
        data,
        core,
        '{"mode":"rule","log-level":"silent","ipv6":false,"rules":["MATCH,DIRECT"],"listeners":[]}',
      );
      final path = '${directory.path}/${testCase.id}-server.json';
      await File(path).writeAsString(candidate);
      final checked = await runner.run(core.binary, [
        '-t',
        '-d',
        directory.path,
        '-f',
        path,
      ]);
      await File(
        '${directory.path}/${testCase.id}-server.log',
      ).writeAsString(checked.output);
      if (checked.exitCode != 0)
        throw StateError(
          'native server rejected default settings; see isolated fixture log',
        );
      var runtime = false;
      if (args.contains('--listen')) {
        if (!Platform.isLinux)
          throw StateError('Runtime listener ownership checks require Linux.');
        final networkSystem = {
          'tun',
          'tproxy',
          'redirect',
        }.contains(definition.id);
        if (networkSystem &&
            Platform.environment['SKY_UI_TEST_ISOLATED_NETNS'] != '1')
          throw StateError(
            'System listeners require the explicitly isolated test network namespace.',
          );
        await codec.preflight(
          PanelData(serverName: 'Empty fixture', address: '127.0.0.1'),
          data,
          false,
        );
        final process = await Process.start(core.binary, [
          '-d',
          directory.path,
          '-f',
          path,
        ]);
        supervisor.processId = process.pid;
        final output = File(
              '${directory.path}/${testCase.id}-runtime.log',
            ).openWrite(),
            errors = File(
              '${directory.path}/${testCase.id}-runtime-errors.log',
            ).openWrite();
        final stdoutDone = output.addStream(process.stdout),
            stderrDone = errors.addStream(process.stderr);
        try {
          await codec.verifyRunning(data, core);
          runtime = true;
        } finally {
          process.kill();
          try {
            await process.exitCode.timeout(const Duration(seconds: 3));
          } on Object {
            process.kill(ProcessSignal.sigkill);
            await process.exitCode;
          }
          await stdoutDone;
          await stderrDone;
          await output.close();
          await errors.close();
          supervisor.processId = null;
        }
      }
      var client = false;
      if (definition.shareable &&
          ClashExporter.compatible(definition.id, normalized)) {
        final endpoint = codec.clientEndpoint(connection, grant, '127.0.0.1');
        final profile = ClashExporter().profile([endpoint]);
        if (secrets['privateKey'] != null &&
            profile.contains(secrets['privateKey']!))
          throw StateError('Server REALITY key leaked.');
        if (profile.contains(key)) throw StateError('Server TLS key leaked.');
        final clientPath = '${directory.path}/${testCase.id}-client.json';
        await File(clientPath).writeAsString(profile);
        final parsed = await runner.run(clientBinary, [
          '-t',
          '-d',
          directory.path,
          '-f',
          clientPath,
        ]);
        await File(
          '${directory.path}/${testCase.id}-client.log',
        ).writeAsString(parsed.output);
        if (parsed.exitCode != 0)
          throw StateError(
            'native client rejected exported profile; see isolated fixture log',
          );
        client = true;
      }
      results.add({
        'id': testCase.id,
        'protocol': definition.id,
        'server': true,
        'runtime': runtime,
        'client': client,
      });
      stdout.writeln(
        '${testCase.id}: server PASS${client ? ', client PASS' : ''}',
      );
      index++;
    } on Object catch (error) {
      results.add({
        'id': testCase.id,
        'protocol': definition.id,
        'error': error.toString(),
      });
      stderr.writeln('${testCase.id}: FAIL $error');
    }
  }
  await File(
    '${directory.path}/summary.json',
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(results));
  stdout.writeln(
    '$index/${cases.length} protocol defaults passed native validation.',
  );
  if (index != cases.length) exitCode = 1;
}

class MatrixSupervisor implements ProcessSupervisor {
  int? processId;
  @override
  bool get supported => Platform.isLinux;
  @override
  Future<ServiceObservation> inspect(ManagedCore core) async =>
      ServiceObservation(
        processId == null ? CoreProcessState.inactive : CoreProcessState.active,
        processId: processId,
      );
  @override
  Future<void> execute(ManagedCore core, CoreOperation operation) =>
      throw UnsupportedError('The fixture never controls system services.');
}

Future<int> freePort() async {
  for (var attempt = 0; attempt < 100; attempt++) {
    final tcp = await ServerSocket.bind('127.0.0.1', 0);
    RawDatagramSocket? udp;
    try {
      udp = await RawDatagramSocket.bind(
        '127.0.0.1',
        tcp.port,
        reuseAddress: false,
        reusePort: false,
      );
      return tcp.port;
    } on SocketException {
      continue;
    } finally {
      udp?.close();
      await tcp.close();
    }
  }
  throw StateError('No isolated fixture port available.');
}
