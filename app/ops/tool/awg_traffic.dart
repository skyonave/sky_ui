import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_ops/src/platform/host.dart';

Future<int> freePort() async {
  final socket = await ServerSocket.bind('127.0.0.1', 0);
  final port = socket.port;
  await socket.close();
  return port;
}

Future<void> main(List<String> args) async {
  require(
    args.length >= 2 && host.uid() == 0,
    'Pass fixture directory and the native sky-ops binary as Linux root.',
  );
  final root = Directory(args[0]).absolute.path,
      helper = File(args[1]).absolute.path;
  require(
    root.contains('protocol-first') && File('$root/fixtures.json').existsSync(),
    'private_fixture_required',
  );
  if (!args.contains('--inside')) {
    final child = await Process.start(
      'unshare',
      [
        '--mount',
        '--net',
        '--fork',
        Platform.resolvedExecutable,
        'run',
        Platform.script.toFilePath(),
        root,
        helper,
        '--inside',
      ],
      environment: {
        ...Platform.environment,
        'SKY_UI_TEST_PARENT_NET_NS': Link('/proc/self/ns/net').targetSync(),
        'SKY_UI_TEST_PARENT_MOUNT_NS': Link('/proc/self/ns/mnt').targetSync(),
      },
      mode: ProcessStartMode.inheritStdio,
    );
    require(await child.exitCode == 0, 'awg_namespace_test_failed');
    return;
  }
  require(
    Platform.environment['SKY_UI_TEST_PARENT_NET_NS'] != null &&
        Link('/proc/self/ns/net').targetSync() !=
            Platform.environment['SKY_UI_TEST_PARENT_NET_NS'] &&
        Link('/proc/self/ns/mnt').targetSync() !=
            Platform.environment['SKY_UI_TEST_PARENT_MOUNT_NS'],
    'private_namespace_required',
  );
  await run(['mount', '--make-rprivate', '/']);
  await run(['mount', '-t', 'tmpfs', 'tmpfs', '/run']);
  await run(['mount', '-t', 'tmpfs', 'tmpfs', '/var/lib']);
  await run(['mount', '-t', 'sysfs', 'sysfs', '/sys']);
  Directory('/run/amneziawg').createSync();
  await run(['ip', 'link', 'set', 'lo', 'up']);
  final item = (jsonDecode(
    File('$root/fixtures.json').readAsStringSync(),
  ) as List).firstWhere((v) => v['engine'] == 'amneziawg');
  final original = object(
        jsonDecode(File(item['server'] as String).readAsStringSync()),
      ),
      profile = object(
        jsonDecode(File(item['client'] as String).readAsStringSync()),
      );
  final port = await freePort(),
      socks = await freePort(),
      httpPort = await freePort();
  original['interfaces'][0]['port'] = port;
  profile['mixed-port'] = socks;
  profile['bind-address'] = '127.0.0.1';
  profile['proxies'][0]['port'] = port;
  final private = '$root/awg-namespace';
  Directory(private).createSync(recursive: true);
  File('$private/client.json').writeAsStringSync(jsonEncode(profile));
  final children = <Process>[], outputTasks = <Future<void>>[];
  final marker = randomId(24);
  HttpServer? echo;
  Future<Process> launch(List<String> args, String name) async {
    File('$private/$name.log').writeAsStringSync('');
    final p = await Process.start(args.first, args.skip(1).toList());
    children.add(p);
    final log = File('$private/$name.log').openWrite(),
        a = p.stdout.listen((b) => log.add(b)),
        b = p.stderr.listen((b) => log.add(b));
    outputTasks.add(
      Future.wait([a.asFuture<void>(), b.asFuture<void>()]).then((_) async {
        await log.close();
      }),
    );
    return p;
  }

  Future<void> stop(Process p) async {
    p.kill();
    try {
      require(
        await p.exitCode.timeout(const Duration(seconds: 12)) == 0,
        'fixture_stop_failed',
      );
    } on TimeoutException {
      p.kill(ProcessSignal.sigkill);
      await p.exitCode;
      throw const OpsError('fixture_stop_timeout');
    }
  }

  Future<Process> server(Map<String, dynamic> config) async {
    File('$private/config.json').writeAsStringSync(jsonEncode(config));
    final p = await launch([
      helper,
      'amnezia',
      'run',
      '$private/config.json',
      '$root/amneziawg',
    ], 'server');
    var ended = false;
    unawaited(p.exitCode.then((_) => ended = true));
    for (var i = 0; i < 100; i++) {
      require(!ended, 'awg_server_exited');
      if (File('$private/server.log').existsSync() &&
          File('$private/server.log').readAsStringSync().contains('3.1 ready'))
        return p;
      await sleep();
    }
    throw const OpsError('awg_server_timeout');
  }

  Future<Process> client() async {
    final p = await launch([
      '$root/mihomo',
      '-f',
      '$private/client.json',
      '-d',
      private,
    ], 'client');
    var ended = false;
    unawaited(p.exitCode.then((_) => ended = true));
    for (var i = 0; i < 100; i++) {
      require(!ended, 'awg_client_exited');
      try {
        final s = await Socket.connect(
          '127.0.0.1',
          socks,
          timeout: const Duration(milliseconds: 100),
        );
        s.destroy();
        return p;
      } on SocketException {
        await sleep();
      }
    }
    throw const OpsError('awg_client_timeout');
  }

  final address = (original['interfaces'][0]['address'] as String)
      .split('/')
      .first;
  Future<bool> fetch() async {
    final r = await command(
      [
        'curl',
        '--fail',
        '--silent',
        '--show-error',
        '--max-time',
        '8',
        '--noproxy',
        '',
        '--socks5-hostname',
        '127.0.0.1:$socks',
        'http://$address:$httpPort/',
      ],
      check: false,
      timeout: const Duration(seconds: 12),
    );
    return r.exitCode == 0 && r.stdout == marker;
  }

  try {
    var service = await server(original);
    echo = await HttpServer.bind(address, httpPort);
    unawaited(
      echo.forEach((r) {
        r.response.write(marker);
        unawaited(r.response.close());
      }),
    );
    var peer = await client();
    require(await fetch(), 'awg_traffic_failed');
    await stop(peer);
    await stop(service);
    final revoked = object(jsonDecode(jsonEncode(original)));
    revoked['interfaces'][0]['peers'] = [];
    service = await server(revoked);
    peer = await client();
    require(!await fetch(), 'awg_revocation_failed');
    await stop(peer);
    await stop(service);
    service = await server(original);
    peer = await client();
    require(await fetch(), 'awg_regrant_failed');
    await stop(peer);
    await stop(service);
    require(
      !exists('/sys/class/net/${original['interfaces'][0]['name']}') &&
          (await command([
                'nft',
                'list',
                'table',
                'ip',
                'sky_ui_awg',
              ], check: false)).exitCode !=
              0,
      'awg_cleanup_failed',
    );
    File('$root/awg-results.json').writeAsStringSync(
      jsonEncode({
        'traffic': true,
        'revocation': true,
        'regrant': true,
        'cleanup': true,
      }),
    );
    stdout.writeln(
      'PASS: AWG 3.1 traffic, cached-profile revocation, regrant and owned network cleanup.',
    );
  } finally {
    for (final p in children) p.kill();
    for (final p in children) {
      try {
        await p.exitCode.timeout(const Duration(seconds: 12));
      } on TimeoutException {
        p.kill(ProcessSignal.sigkill);
        await p.exitCode;
      }
    }
    if (echo != null) await echo.close(force: true);
    await Future.wait(outputTasks);
  }
}
