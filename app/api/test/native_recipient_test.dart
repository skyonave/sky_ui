import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';

class FixtureSupervisor implements ProcessSupervisor {
  Process? process;
  bool exited = false;
  @override
  bool get supported => Platform.isLinux;
  @override
  Future<ServiceObservation> inspect(ManagedCore core) async =>
      ServiceObservation(
        process == null || exited
            ? CoreProcessState.inactive
            : CoreProcessState.active,
        processId: process?.pid,
      );
  @override
  Future<void> execute(ManagedCore core, CoreOperation operation) async {
    if (operation == CoreOperation.stop || operation == CoreOperation.restart)
      await stop();
    if (operation != CoreOperation.stop && (process == null || exited)) {
      final child = await Process.start(core.binary, [
        '-d',
        core.directory,
        '-f',
        core.configuration,
      ]);
      process = child;
      exited = false;
      unawaited(child.stdout.drain<void>());
      unawaited(child.stderr.drain<void>());
      unawaited(
        child.exitCode.then((_) {
          if (identical(process, child)) exited = true;
        }),
      );
    }
  }

  Future<void> stop() async {
    final child = process;
    if (child == null) return;
    child.kill();
    try {
      await child.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
    }
    if (identical(process, child)) {
      process = null;
      exited = false;
    }
  }
}

Future<int> availablePort() async {
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
  throw StateError('No fixture port.');
}

void main() {
  final binary = Platform.environment['SKY_UI_NATIVE_TEST_BINARY'];
  test(
    'native isolated recipient ports survive independent revoke, enable and delete',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sky-ui-private-native-',
      );
      final supervisor = FixtureSupervisor(),
          clients = <Process>[],
          httpClients = <HttpClient>[];
      PanelRepository? repository;
      MihomoAdapter? adapter;
      HttpServer? echo;
      try {
        echo = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        const marker = 'isolated-private-native-recipient-fixture';
        unawaited(
          echo.forEach((request) async {
            request.response.write(marker);
            await request.response.close();
          }),
        );
        final controllerPort = await availablePort(),
            coreDirectory = await Directory('${directory.path}/core').create();
        final core = ManagedCore(
          id: 'primary',
          coreId: 'mihomo',
          service: 'fixture-only-never-systemd.service',
          binary: binary!,
          directory: coreDirectory.path,
          configuration: '${coreDirectory.path}/config.json',
          controller: Uri.parse('http://127.0.0.1:$controllerPort'),
          secret: 'private-fixture-controller-only',
        );
        await File(core.configuration).writeAsString(
          jsonEncode({
            'external-controller': '127.0.0.1:$controllerPort',
            'secret': core.secret,
            'mode': 'rule',
            'log-level': 'silent',
            'listeners': [],
            'rules': ['MATCH,DIRECT'],
          }),
        );
        adapter = MihomoAdapter(const NativeCommandRunner());
        final manager = CoreManager(
          core: core,
          adapters: {'mihomo': adapter},
          supervisor: supervisor,
          stateDirectory: '${directory.path}/instances',
        );
        await manager.initialize();
        repository = PanelRepository(
          '${directory.path}/panel.sqlite',
          defaultAddress: '127.0.0.1',
        );
        final codec = MihomoConfiguration(supervisor: supervisor, core: core);
        final panel = PanelService(
          config: ServerConfig(
            port: 39242,
            webOrigin: Uri.parse('http://127.0.0.1:39242'),
            publicDirectory: directory.path,
            dataDirectory: directory.path,
            core: core,
            requireOwnerAuth: false,
          ),
          manager: manager,
          repository: repository,
          codecs: {'mihomo': codec},
          exporter: ClashExporter(),
        );
        await panel.initialize();
        await panel.executeCore(CoreOperation.start);
        final created = await panel.saveConnection(
          repository.revision,
          Connection(
            id: '',
            name: 'Native fixture',
            coreId: 'mihomo',
            protocolId: 'shadowsocks',
            port: await availablePort(),
            settings: const {'listen': '127.0.0.1', 'native.udp': 'true'},
          ),
        );
        final connection = created.connections.single;
        await panel.saveRecipient(
          repository.revision,
          Recipient(
            id: '',
            name: 'First fixture',
            connectionIds: [connection.id],
          ),
        );
        await panel.saveRecipient(
          repository.revision,
          Recipient(
            id: '',
            name: 'Second fixture',
            connectionIds: [connection.id],
          ),
        );
        final before = repository.read(),
            first = before.recipients.first,
            second = before.recipients.last;
        expect(
          before.grants.first.credentials['port'],
          isNot(before.grants.last.credentials['port']),
        );
        Future<HttpClient> clientFor(String id) async {
          final data = repository!.read(),
              grant = data.grants.firstWhere((g) => g.recipientId == id);
          final profile =
              jsonDecode(
                    ClashExporter().profile([
                      codec.clientEndpoint(
                        data.connections.firstWhere(
                          (c) => c.value.id == connection.id,
                        ),
                        grant,
                        '127.0.0.1',
                      ),
                    ]),
                  )
                  as Map<String, dynamic>;
          final port = await availablePort();
          profile['mixed-port'] = port;
          profile['bind-address'] = '127.0.0.1';
          profile['log-level'] = 'silent';
          final home = await Directory('${directory.path}/client-$id').create(),
              path = '${directory.path}/client-$id/profile.json';
          await File(path).writeAsString(jsonEncode(profile));
          final child = await Process.start(binary, [
            '-d',
            home.path,
            '-f',
            path,
          ]);
          clients.add(child);
          unawaited(child.stdout.drain<void>());
          unawaited(child.stderr.drain<void>());
          var ready = false;
          for (var attempt = 0; attempt < 40; attempt++) {
            try {
              final probe = await Socket.connect(
                '127.0.0.1',
                port,
                timeout: const Duration(milliseconds: 100),
              );
              probe.destroy();
              ready = true;
              break;
            } on SocketException {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
          expect(ready, isTrue);
          final http = HttpClient()
            ..connectionTimeout = const Duration(seconds: 2)
            ..findProxy = ((_) => 'PROXY 127.0.0.1:$port');
          httpClients.add(http);
          return http;
        }

        final a = await clientFor(first.id), b = await clientFor(second.id);
        Future<bool> reaches(HttpClient client) async {
          try {
            final request = await client
                .getUrl(
                  Uri.parse('http://127.0.0.1:${echo!.port}/private-fixture'),
                )
                .timeout(const Duration(seconds: 3));
            request.persistentConnection = false;
            final response = await request.close().timeout(
                  const Duration(seconds: 3),
                ),
                body = await utf8.decoder
                    .bind(response)
                    .join()
                    .timeout(const Duration(seconds: 3));
            return response.statusCode == 200 && body == marker;
          } on Object {
            return false;
          }
        }

        expect(await reaches(a), isTrue);
        expect(await reaches(b), isTrue);
        await panel.saveRecipient(
          repository.revision,
          before.publicRecipient(first).copyWith(enabled: false),
          id: first.id,
        );
        expect(await reaches(a), isFalse);
        expect(await reaches(b), isTrue);
        expect(
          repository.read().grants.last.credentials,
          before.grants.last.credentials,
        );
        expect(
          (await panel.snapshot()).recipients
              .firstWhere((r) => r.id == second.id)
              .connectionPorts[connection.id],
          int.parse(before.grants.last.credentials['port']!),
        );
        await panel.saveRecipient(
          repository.revision,
          before.publicRecipient(first).copyWith(enabled: true),
          id: first.id,
        );
        expect(await reaches(a), isTrue);
        expect(await reaches(b), isTrue);
        expect(
          repository.read().grants.first.credentials,
          before.grants.first.credentials,
        );
        await panel.deleteRecipient(repository.revision, first.id);
        expect(await reaches(a), isFalse);
        expect(await reaches(b), isTrue);
      } finally {
        for (final http in httpClients) http.close(force: true);
        for (final child in clients) {
          child.kill();
          try {
            await child.exitCode.timeout(const Duration(seconds: 3));
          } on Object {
            child.kill(ProcessSignal.sigkill);
            await child.exitCode;
          }
        }
        await adapter?.close();
        await supervisor.stop();
        await echo?.close(force: true);
        repository?.close();
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isLinux || binary == null,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
