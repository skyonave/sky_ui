import 'dart:io';

import 'package:sky_ui_api/src/infrastructure/process/command_runner.dart';
import 'package:sky_ui_api/src/infrastructure/process/ssh_servers.dart';
import 'package:sky_ui_api/src/shared/api_exception.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';

const hostKey =
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

class TestSshRunner implements CommandRunner {
  List<String> command = [];
  int result = 0;

  @override
  Future<CommandResult> run(
    String executable,
    List<String> arguments, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    command = [executable, ...arguments];
    if (executable.endsWith('/ssh-keygen')) {
      File(arguments.last).writeAsStringSync('test-private-key');
      File('${arguments.last}.pub').writeAsStringSync('$hostKey test-panel\n');
      return const CommandResult(0, '');
    }
    return CommandResult(result, result == 0 ? 'active\n' : 'test-private-key');
  }
}

void main() {
  late Directory data;
  late TestSshRunner runner;
  late SshServers servers;

  setUp(() async {
    data = await Directory.systemTemp.createTemp('sky-ui-ssh-test-');
    runner = TestSshRunner();
    servers = SshServers(data.path, runner);
  });

  tearDown(() => data.delete(recursive: true));

  Future<ServerNode> add({String host = 'VPS.example', int port = 2222}) =>
      servers.add(name: 'VPS', host: host, port: port, hostKey: hostKey);

  test(
    'pins a node host key and sends only a predefined SSH operation',
    () async {
      final node = await add();
      expect(node.host, 'vps.example');
      expect(node.toJson().toString(), isNot(contains('test-private-key')));
      expect(
        SshServers(data.path, runner).list().single.toJson(),
        node.toJson(),
      );
      expect(await servers.execute(node.id, ServerOperation.status), 'active');
      final path = '${data.path}/remote-servers/${node.id}';
      expect(
        File('$path/known_hosts').readAsStringSync(),
        'sky-ui-node $hostKey\n',
      );
      expect(runner.command, contains('StrictHostKeyChecking=yes'));
      expect(runner.command, contains('UserKnownHostsFile=$path/known_hosts'));
      expect(runner.command, contains('ClearAllForwardings=yes'));
      expect(runner.command.sublist(runner.command.length - 3), [
        '--',
        'vps.example',
        'status',
      ]);
      runner.result = 255;
      await expectLater(
        servers.execute(node.id, ServerOperation.status),
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'server_ssh_failed',
          ),
        ),
      );
      await servers.remove(node.id);
      expect(servers.list(), isEmpty);
      expect(File('$path/identity').existsSync(), isFalse);
    },
  );

  test('rejects option injection and duplicate node enrollment', () async {
    await expectLater(
      add(host: '-oProxyCommand=anything'),
      throwsA(isA<ApiException>()),
    );
    expect(runner.command, isEmpty);
    await add();
    await expectLater(
      add(host: 'vps.example'),
      throwsA(
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'server_duplicate',
        ),
      ),
    );
    await expectLater(
      servers.execute('../unrelated', ServerOperation.stop),
      throwsA(
        isA<ApiException>().having((error) => error.status, 'status', 404),
      ),
    );
  });

  test(
    'reports invalid fields and accepts the full public host key line',
    () async {
      await expectLater(
        servers.add(
          name: 'DE',
          host: 'root@192.0.2.4',
          port: 22,
          hostKey: hostKey.split(' ').last,
        ),
        throwsA(
          isA<ApiException>().having((e) => e.fields, 'fields', {
            'host': 'host',
            'hostKey': 'hostKey',
          }),
        ),
      );
      expect(runner.command, isEmpty);
      final node = await servers.add(
        name: 'DE',
        host: '192.0.2.4',
        port: 22,
        hostKey: '$hostKey root@test\n',
        endpoint: 'VPN.Example.com',
      );
      expect(node.endpoint, 'vpn.example.com');
      final path = '${data.path}/remote-servers/${node.id}';
      final pin = File('$path/known_hosts').readAsStringSync();
      final key = File('$path/identity').readAsStringSync();
      await servers.updateEndpoint(node.id, 'New.Example.com');
      expect(servers.list().single.endpoint, 'new.example.com');
      expect(servers.list().single.host, '192.0.2.4');
      expect(File('$path/known_hosts').readAsStringSync(), pin);
      expect(File('$path/identity').readAsStringSync(), key);
      await expectLater(
        servers.updateEndpoint(node.id, 'https://bad.example/'),
        throwsA(
          isA<ApiException>().having((e) => e.fields, 'fields', {
            'endpoint': 'host',
          }),
        ),
      );
      expect(servers.list().single.endpoint, 'new.example.com');
      await servers.updateEndpoint(node.id, '');
      expect(servers.list().single.endpoint, isNull);
    },
  );
}
