import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_ops/src/platform/host.dart';

import 'network_probe.dart';

Future<int> freePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> main(List<String> args) async {
  require(
    args.isNotEmpty,
    'Pass a generated protocol-first fixture directory.',
  );
  final root = Directory(args.first).absolute.path;
  require(root.contains('protocol-first'), 'private_fixture_required');
  require(Platform.isLinux && host.uid() == 0, 'linux_root_required');
  if (!args.contains('--inside')) {
    final child = await Process.start(
      'unshare',
      [
        '--net',
        '--fork',
        Platform.resolvedExecutable,
        'run',
        Platform.script.toFilePath(),
        ...args,
        '--inside',
      ],
      environment: {
        ...Platform.environment,
        'SKY_UI_TEST_PARENT_NET_NS': Link('/proc/self/ns/net').targetSync(),
      },
      mode: ProcessStartMode.inheritStdio,
    );
    require(await child.exitCode == 0, 'traffic_namespace_test_failed');
    return;
  }
  require(
    Platform.environment['SKY_UI_TEST_PARENT_NET_NS'] != null &&
        Link('/proc/self/ns/net').targetSync() !=
            Platform.environment['SKY_UI_TEST_PARENT_NET_NS'],
    'private_network_required',
  );
  await run(['ip', 'link', 'set', 'lo', 'up']);
  final marker = randomId(20),
      echo = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final echoTask = echo.forEach((r) {
    r.response
      ..headers.contentType = ContentType.text
      ..write(marker);
    unawaited(r.response.close());
  });
  final udpEcho = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  final udpEvents = udpEcho.listen((event) {
    if (event == RawSocketEvent.read) {
      Datagram? packet;
      while ((packet = udpEcho.receive()) != null) {
        udpEcho.send(packet!.data, packet.address, packet.port);
      }
    }
  });
  final context = SecurityContext()
    ..useCertificateChain('$root/cert.pem')
    ..usePrivateKey('$root/key.pem')
    ..setAlpnProtocols(['h2', 'http/1.1'], true);
  final handshake = await HttpServer.bindSecure(
    InternetAddress.loopbackIPv4,
    0,
    context,
  );
  final handshakeTask = handshake.forEach((r) {
    r.response.write(marker);
    unawaited(r.response.close());
  });
  final nativePort = await freePort();
  File('$root/handshake-target.json').writeAsStringSync(
    jsonEncode({
      'inbounds': [
        {
          'type': 'http',
          'listen': '127.0.0.1',
          'listen_port': nativePort,
          'tls': {
            'enabled': true,
            'certificate_path': '$root/cert.pem',
            'key_path': '$root/key.pem',
            'alpn': ['h2', 'http/1.1'],
          },
        },
      ],
    }),
  );
  final children = <Process>[], logs = <Future<void>>[];
  Future<Process> launch(List<String> args, String log) async {
    final process = await Process.start(
      args.first,
      args.skip(1).toList(),
      workingDirectory: root,
    );
    children.add(process);
    final output = File(log).openWrite();
    final a = process.stdout.listen(output.add),
        b = process.stderr.listen(output.add);
    logs.add(
      Future.wait([a.asFuture<void>(), b.asFuture<void>()]).then((_) async {
        await output.close();
      }),
    );
    return process;
  }

  final native = await launch([
    '$root/sing-box',
    'run',
    '-c',
    '$root/handshake-target.json',
  ], '$root/handshake-target.log');
  await sleep(500);
  var nativeExited = false;
  unawaited(native.exitCode.then((_) => nativeExited = true));
  require(!nativeExited, 'native_handshake_failed');
  final resultFile = File('$root/traffic-results.json');
  final previous = args.contains('--only-failed') && resultFile.existsSync()
      ? jsonDecode(resultFile.readAsStringSync()) as List
      : [];
  bool complete(dynamic r) =>
      r['passed'] == true &&
      (!args.contains('--udp') || r['udp'] != null) &&
      (!args.contains('--auth') || r['rejectsWrongCredentials'] == true);
  final results = previous.where(complete).map(object).toList(),
      passed = previous.where(complete).map((r) => r['id']).toSet();
  try {
    for (final value
        in jsonDecode(File('$root/fixtures.json').readAsStringSync()) as List) {
      final fixture = object(value), id = fixture['id'] as String;
      if (fixture['engine'] == 'amneziawg' || passed.contains(id)) continue;
      final processes = <Process>[];
      var stage = 'start';
      Map<String, dynamic> result;
      try {
        final server = object(
              jsonDecode(File(fixture['server'] as String).readAsStringSync()),
            ),
            client = object(
              jsonDecode(File(fixture['client'] as String).readAsStringSync()),
            ),
            engine = fixture['engine'] as String;
        final port = await freePort(),
            socks = await freePort(),
            inbounds =
                server[engine == 'mihomo' ? 'listeners' : 'inbounds'] as List;
        if (engine == 'xray') {
          server['log'] = {'loglevel': 'debug'};
          server['outbounds'][0]['settings'] = {
            'finalRules': [
              {
                'action': 'allow',
                'ip': ['127.0.0.0/8'],
              },
            ],
          };
        }
        for (final inbound in inbounds) {
          require(inbound['listen'] == '127.0.0.1', 'nonloopback_fixture');
          inbound[engine == 'sing-box' ? 'listen_port' : 'port'] = port;
          if (inbound['streamSettings']?['security'] == 'reality')
            inbound['streamSettings']['realitySettings']['target'] =
                '127.0.0.1:$nativePort';
          if (inbound['tls']?['reality']?['enabled'] == true)
            inbound['tls']['reality']['handshake'] = {
              'server': 'localhost',
              'server_port': handshake.port,
            };
        }
        if (fixture['clientEngine'] == 'sing-box') {
          client['inbounds'][0]['listen_port'] = socks;
          client['outbounds'][0]['server_port'] = port;
        } else {
          client['mixed-port'] = socks;
          for (final proxy in client['proxies']) proxy['port'] = port;
        }
        for (final role in [
          ('server', server, engine),
          ('client', client, fixture['clientEngine'] as String),
        ]) {
          final home = '$root/$id-${role.$1}',
              path = '$root/$id-${role.$1}.active.json';
          Directory(home).createSync(recursive: true);
          File(path).writeAsStringSync(jsonEncode(role.$2));
          final args = role.$3 == 'mihomo'
              ? ['$root/mihomo', '-f', path, '-d', home]
              : role.$3 == 'xray'
              ? ['$root/xray', 'run', '-config', path]
              : ['$root/sing-box', 'run', '-c', path];
          processes.add(await launch(args, '$root/$id-${role.$1}.log'));
        }
        var exited = false;
        for (final p in processes)
          unawaited(p.exitCode.then((_) => exited = true));
        final end = DateTime.now().add(const Duration(seconds: 10));
        while (true) {
          require(!exited, 'fixture_process_exited');
          try {
            final probe = await Socket.connect(
              '127.0.0.1',
              socks,
              timeout: const Duration(milliseconds: 200),
            );
            probe.destroy();
            break;
          } on SocketException {
            require(DateTime.now().isBefore(end), 'fixture_listener_timeout');
            await sleep();
          }
        }
        stage = 'authenticated traffic';
        final response = await command([
          'curl',
          '--fail',
          '--silent',
          '--show-error',
          '--max-time',
          '15',
          '--noproxy',
          '',
          '--socks5-hostname',
          '127.0.0.1:$socks',
          'http://127.0.0.1:${echo.port}/',
        ], timeout: const Duration(seconds: 20));
        require(response.stdout == marker, 'fixture_payload_mismatch');
        result = {'id': id, 'passed': true};
        Future<void> observed(int target) async {
          for (var n = 0; n < 40; n++) {
            if (utf8
                .decode(
                  File('$root/$id-server.log').readAsBytesSync(),
                  allowMalformed: true,
                )
                .contains('127.0.0.1:$target'))
              return;
            await sleep(50);
          }
          throw const OpsError('native_server_bypassed');
        }

        await observed(echo.port);
        if (args.contains('--udp')) {
          stage = 'UDP traffic';
          if (fixture['protocol'] == 'naive') {
            result['udp'] = 'not-supported';
          } else {
            await probeUdp(socks, udpEcho.port, utf8.encode('$marker/$id'));
            await observed(udpEcho.port);
            result['udp'] = true;
          }
        }
        if (args.contains('--auth')) {
          stage = 'credential rejection';
          final accepted = processes.removeLast();
          accepted.kill();
          try {
            await accepted.exitCode.timeout(const Duration(seconds: 3));
          } on TimeoutException {
            accepted.kill(ProcessSignal.sigkill);
            await accepted.exitCode;
          }
          final rejected = object(jsonDecode(jsonEncode(client)));
          final proxy = object(
            fixture['clientEngine'] == 'sing-box'
                ? rejected['outbounds'][0]
                : rejected['proxies'][0],
          );
          invalidateCredentials(proxy);
          rejected[fixture['clientEngine'] == 'sing-box'
                  ? 'outbounds'
                  : 'proxies'][0] =
              proxy;
          final path = '$root/$id-rejected.json', home = '$root/$id-rejected';
          Directory(home).createSync(recursive: true);
          File(path).writeAsStringSync(jsonEncode(rejected));
          final bad = await launch(
            fixture['clientEngine'] == 'mihomo'
                ? ['$root/mihomo', '-f', path, '-d', home]
                : ['$root/sing-box', 'run', '-c', path],
            '$root/$id-rejected.log',
          );
          processes.add(bad);
          var ended = false, serverEnded = false;
          unawaited(bad.exitCode.then((_) => ended = true));
          unawaited(processes.first.exitCode.then((_) => serverEnded = true));
          var listening = false;
          for (var n = 0; n < 50; n++) {
            require(!ended, 'rejected_fixture_invalid');
            try {
              final probe = await Socket.connect(
                '127.0.0.1',
                socks,
                timeout: const Duration(milliseconds: 100),
              );
              probe.destroy();
              listening = true;
              break;
            } on SocketException {
              await sleep();
            }
          }
          require(listening, 'rejected_fixture_listener_timeout');
          final denied = await command(
            [
              'curl',
              '--fail',
              '--silent',
              '--max-time',
              '3',
              '--noproxy',
              '',
              '--socks5-hostname',
              '127.0.0.1:$socks',
              'http://127.0.0.1:${echo.port}/',
            ],
            check: false,
            timeout: const Duration(seconds: 5),
          );
          require(
            denied.exitCode != 0 && !ended && !serverEnded,
            'wrong_credentials_accepted',
          );
          result['rejectsWrongCredentials'] = true;
        }
      } on Object catch (error) {
        result = {
          'id': id,
          'passed': false,
          'error': error is OpsError ? error.code : 'fixture_failed',
          'stage': stage,
        };
      } finally {
        for (final p in processes) p.kill();
        for (final p in processes) {
          try {
            await p.exitCode.timeout(const Duration(seconds: 3));
          } on TimeoutException {
            p.kill(ProcessSignal.sigkill);
            await p.exitCode;
          }
        }
      }
      results.add(result);
      resultFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(results),
      );
      stdout.writeln(jsonEncode(result));
    }
  } finally {
    for (final p in children) p.kill();
    for (final p in children) {
      try {
        await p.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        p.kill(ProcessSignal.sigkill);
        await p.exitCode;
      }
    }
    await echo.close(force: true);
    await udpEvents.cancel();
    udpEcho.close();
    await handshake.close(force: true);
    await Future.wait([echoTask, handshakeTask]);
    await Future.wait(logs);
  }
  require(results.every((r) => r['passed'] == true), 'protocol_traffic_failed');
}
