import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:yaml/yaml.dart';

import '../../platform/host.dart';
import '../../shared/artifacts.dart';
import '../engines/amnezia.dart';
import '../engines/installer.dart' show buildAwg;
import 'node_diagnostics.dart';
import 'node_routing_data.dart';

const nodeRoot = '/var/lib/sky-ui-node';
const nodeProgram = '/usr/local/libexec/sky-ui-node';
const nodeEngines = ['mihomo', 'sing-box', 'xray', 'amneziawg'];
const nodeVerbs = [
  'inspect',
  'diagnose',
  'status',
  'logs',
  'start',
  'stop',
  'restart',
  'validate',
  'deploy',
  'rollback',
  'install',
  'update',
  'remove',
  'probe',
];

String nodeBaseline(String engine) => switch (engine) {
  'mihomo' => '{"mode":"rule","log-level":"info","listeners":[]}\n',
  'amneziawg' => '{"version":"3.1","interfaces":[]}\n',
  _ => '{}\n',
};

({Set<int> tcp, Set<int> udp}) nodeConfigurationBindings(
  String engine,
  Map document,
) {
  final tcp = <int>{}, udp = <int>{};
  final key = engine == 'mihomo'
      ? 'listeners'
      : engine == 'amneziawg'
      ? 'interfaces'
      : 'inbounds';
  for (final item in document[key] as List? ?? const []) {
    if (item is! Map) continue;
    final port = item['port'] ?? item['listen_port'];
    if (port is! int || port < 1024 || port > 65535) continue;
    final type = item['type'] ?? item['protocol'];
    if (engine == 'mihomo' && {'trusttunnel', 'tunnel'}.contains(type)) {
      final network = item['network'];
      final transports = network is List
          ? network.whereType<String>().toSet()
          : {'tcp', 'udp'};
      if (transports.contains('tcp')) tcp.add(port);
      if (transports.contains('udp')) udp.add(port);
      continue;
    }
    if (type == 'shadowsocks') {
      final settings = item['settings'];
      final network = engine == 'xray' && settings is Map
          ? settings['network']
          : item['network'];
      final transports = network is String
          ? network.split(',').map((value) => value.trim()).toSet()
          : {'tcp', 'udp'};
      if (transports.contains('tcp')) tcp.add(port);
      if (transports.contains('udp') && item['udp'] != false) udp.add(port);
      continue;
    }
    final datagrams =
        engine == 'amneziawg' ||
        {
          'tuic',
          'tuic-v4',
          'hysteria2',
          'hysteria2-realm',
          'shadowquic',
        }.contains(type) ||
        type == 'naive' && item['network'] == 'udp' ||
        type == 'mieru' && item['transport'] == 'UDP';
    (datagrams ? udp : tcp).add(port);
  }
  return (tcp: tcp, udp: udp);
}

/// A forced SSH command exposes only these fixed operations, never shell input.
({String verb, String engine}) parseNodeCommand(List<String> args) {
  require(args.length == 1 || args.length == 2, 'request_invalid');
  if (args.length == 1 && {'inventory', 'ports'}.contains(args.first))
    return (verb: args.first, engine: '');
  require(
    args.length == 2 &&
        nodeVerbs.contains(args[0]) &&
        nodeEngines.contains(args[1]),
    'request_invalid',
  );
  return (verb: args[0], engine: args[1]);
}

/// Receive one bounded document; disconnects never leave a partial file trusted.
Future<String> _input() async {
  final bytes = BytesBuilder(copy: false);
  await for (final part in stdin.timeout(const Duration(seconds: 15))) {
    require(bytes.length + part.length <= 1114112, 'request_invalid');
    bytes.add(part);
  }
  return utf8.decode(bytes.takeBytes());
}

class NodeEngine {
  NodeEngine(this.engine) {
    require(nodeEngines.contains(engine), 'core_unsupported');
  }
  final String engine;
  String get directory => '$nodeRoot/engines/$engine';
  String get configuration =>
      engine == 'mihomo' ? '$nodeRoot/config.json' : '$directory/config.json';
  String get unit => 'sky-ui-node-$engine.service';
  String get slots => '$nodeProgram/cores/$engine';
  String get binary => engine == 'mihomo' && !exists('$slots/current')
      ? '$nodeProgram/mihomo'
      : '$slots/current/$engine';
  String get undo => '$directory/undo.json';
  bool get installed => File(binary).existsSync();

  Future<void> _lifecycle(String operation) async {
    require(
      {'start', 'stop', 'restart'}.contains(operation),
      'request_invalid',
    );
    // systemd may have already unloaded an inactive unit; start loads it again.
    if (operation != 'stop')
      await command(['systemctl', 'reset-failed', unit], check: false);
    await run(['systemctl', operation, unit]);
  }

  Future<void> initialize() async {
    host.mkdir('$nodeRoot/engines', mode: 0x1ed);
    host.mkdir(directory, mode: 0x1ed);
    final user = await account('sky-ui-relay');
    host.mkdir('$directory/runtime', uid: user.uid, gid: user.gid, mode: 0x1e8);
    if (!exists(configuration))
      host.atomic(
        configuration,
        utf8.encode(nodeBaseline(engine)),
        mode: 0x1a0,
        gid: user.gid,
      );
    host.trusted(configuration);
    if (exists('$slots/activation.json')) {
      final intent = readJson('$slots/activation.json');
      final previous = intent['previous'];
      if (intent['autoStart'] == true)
        await run(['systemctl', 'disable', '--now', unit]);
      require(
        previous == null || previous is String && parent(previous) == slots,
        'unsafe_file',
      );
      if (previous is String) {
        host.trusted(previous, directory: true);
        switchLink('$slots/current', previous);
        if (engine == 'mihomo')
          switchLink('$nodeProgram/mihomo', '$slots/current/mihomo');
      } else {
        await run(['systemctl', 'stop', unit]);
        unlink('$slots/current');
        if (engine == 'mihomo') unlink('$nodeProgram/mihomo');
      }
      if (intent['running'] == true && previous != null) {
        await _lifecycle('restart');
        await _verifyConfiguration();
      }
      unlink('$slots/activation.json');
    }
  }

  Future<Map<String, Object?>> inspect({
    bool diagnose = false,
    bool validateNative = true,
  }) async {
    final state = (await run([
      'systemctl',
      'show',
      '-p',
      'ActiveState',
      '--value',
      unit,
    ])).trim();
    final pid =
        int.tryParse(
          (await run(['systemctl', 'show', '-p', 'MainPID', '--value', unit]))
              .trim(),
        ) ??
        0;
    String? version;
    final linked = exists('$slots/current') ? resolved('$slots/current') : null;
    if (linked != null) require(parent(linked) == slots, 'unsafe_file');
    final receipt = linked == null
        ? '$slots/missing.json'
        : '$linked/artifact.json';
    if (exists(receipt)) version = readJson(receipt)['version'] as String?;
    if (version == null && engine == 'mihomo' && installed) {
      final output = await run([
        'runuser',
        '-u',
        'sky-ui-relay',
        '--',
        binary,
        '-v',
      ], timeout: const Duration(seconds: 3));
      final match = RegExp(
        r'\bMihomo Meta (v[0-9]+\.[0-9]+\.[0-9]+)\b',
        caseSensitive: false,
      ).firstMatch(output);
      version = match?.group(1);
    }
    final document = readText(configuration, 524288);
    bool? valid;
    String? code;
    if (diagnose && installed && validateNative) {
      try {
        await validate(configuration, prepareAssets: false);
        valid = true;
      } on OpsError catch (error) {
        valid = false;
        code = error.code == 'command_timeout'
            ? 'validator_timeout'
            : 'native_invalid';
      }
    }
    final sockets = <Map<String, Object?>>[];
    if (diagnose && pid > 0) {
      final pids = await _servicePids(pid);
      for (final udp in [false, true]) {
        final output = await run(['ss', udp ? '-Hlunp' : '-Hltnp']);
        for (final line in output.split('\n')) {
          if (!pids.any((value) => line.contains('pid=$value,'))) continue;
          final fields = line.trim().split(RegExp(r'\s+'));
          if (fields.length < 5) continue;
          final endpoint = fields[3];
          final port = int.tryParse(endpoint.split(':').last);
          if (port != null) {
            var address = endpoint
                .substring(0, endpoint.lastIndexOf(':'))
                .replaceAll('[', '')
                .replaceAll(']', '');
            if (address == '*') address = '::';
            String? interface;
            if (engine == 'amneziawg') {
              final config = jsonDecode(document) as Map;
              for (final item in config['interfaces'] as List) {
                if (item['port'] == port &&
                    Directory('/sys/class/net/${item['name']}').existsSync())
                  interface = item['name'] as String;
              }
            }
            sockets.add({
              'host': address,
              'port': port,
              'udp': udp,
              if (interface != null) 'interface': interface,
            });
          }
        }
      }
    }
    return {
      'coreId': engine,
      'installed': installed,
      'state': state,
      'version': version,
      'platform': targetPlatform(),
      'hash': digest(utf8.encode(document)),
      'protocol': 3,
      if (diagnose) ...{
        'pid': pid,
        'nativeValid': valid,
        'nativeCode': code,
        'listeners': sockets,
      },
    };
  }

  Future<Set<int>> _servicePids(int pid) async {
    final pids = <int>{pid};
    // The AWG supervisor owns one child process per interface.
    if (engine == 'amneziawg') {
      // Dart starts processes from worker threads, not necessarily the main task.
      final tasks = Directory('/proc/$pid/task');
      if (await tasks.exists())
        for (final task in tasks.listSync(followLinks: false)) {
          final file = File('${task.path}/children');
          if (!await file.exists()) continue;
          try {
            pids.addAll(
              (await file.readAsString())
                  .trim()
                  .split(RegExp(r'\s+'))
                  .map(int.tryParse)
                  .whereType<int>(),
            );
          } on FileSystemException {
            /* A task may finish during inspection. */
          }
        }
    }
    return pids;
  }

  Future<void> validate(
    String path, {
    String? executable,
    bool prepareAssets = true,
  }) async {
    require(installed || executable != null, 'binary_missing');
    if (engine == 'amneziawg') {
      loadAwg(path);
      return;
    }
    if (prepareAssets)
      await prepareNodeRoutingData(
        engine,
        path,
        engine == 'mihomo' ? '$nodeRoot/runtime' : '$directory/runtime',
      );
    await run([
      'runuser',
      '-u',
      'sky-ui-relay',
      '--',
      if (engine == 'xray') ...[
        'env',
        'XRAY_LOCATION_ASSET=$directory/runtime',
      ],
      executable ?? binary,
      ...switch (engine) {
        'mihomo' => ['-t', '-d', '$nodeRoot/runtime', '-f', path],
        'sing-box' => ['check', '-c', path],
        _ => ['run', '-test', '-config', path],
      },
    ], timeout: const Duration(seconds: 25));
  }

  Future<void> _write(String path, String value) async {
    final user = await account('sky-ui-relay');
    host.atomic(path, utf8.encode(value), gid: user.gid, mode: 0x1a0);
  }

  Future<void> _verify(Set<int> tcp, Set<int> udp) async {
    for (var attempt = 0; attempt < 25; attempt++) {
      final pid =
          int.tryParse(
            (await run(['systemctl', 'show', '-p', 'MainPID', '--value', unit]))
                .trim(),
          ) ??
          0;
      if (pid > 0 && await active(unit)) {
        final pids = await _servicePids(pid);
        Future<bool> owned(Set<int> ports, bool udp) async {
          for (final port in ports) {
            final output = await run([
              'ss',
              udp ? '-Hlunp' : '-Hltnp',
              'sport',
              '=',
              ':$port',
            ]);
            if (!pids.any((value) => output.contains('pid=$value,')))
              return false;
          }
          return true;
        }

        if (await owned(tcp, false) && await owned(udp, true)) return;
      }
      await sleep(100);
    }
    throw const OpsError('listener_not_ready');
  }

  Future<void> _verifyConfiguration() async {
    final ports = nodeConfigurationBindings(
      engine,
      loadYaml(readText(configuration, 524288)) as Map,
    );
    await _verify(ports.tcp, ports.udp);
  }

  Future<void> deploy(Map<String, dynamic> input) async {
    final tx = input['transaction'];
    require(
      tx is String && RegExp(r'^tx_[A-Za-z0-9_-]{22}$').hasMatch(tx),
      'request_invalid',
    );
    final previous = input['previous'], document = input['configuration'];
    require(
      previous is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(previous) &&
          document is String &&
          utf8.encode(document).length <= 524288,
      'request_invalid',
    );
    if (exists('$directory/aborted'))
      require(readText('$directory/aborted') != tx, 'transaction_aborted');
    final old = readText(configuration, 524288);
    require(
      digest(utf8.encode(old)) == previous,
      'route_configuration_out_of_sync',
    );
    final tcp = nodePorts(input['tcp']), udp = nodePorts(input['udp']);
    await _write('$directory/candidate.json', document as String);
    try {
      await validate('$directory/candidate.json');
      final running = await active(unit);
      final enabled =
          (await command([
            'systemctl',
            'is-enabled',
            unit,
          ], check: false)).stdout.toString().trim() ==
          'enabled';
      atomicJson(undo, {
        'transaction': tx,
        'configuration': old,
        'running': running,
        'enabled': enabled,
      }, mode: 0x180);
      await _write(configuration, document);
      if (running || tcp.isNotEmpty || udp.isNotEmpty) {
        await _lifecycle('restart');
        await _verify(tcp, udp);
        if (tcp.isNotEmpty || udp.isNotEmpty)
          await run(['systemctl', 'enable', unit]);
      }
    } finally {
      unlink('$directory/candidate.json');
    }
  }

  Future<void> rollback(String tx) async {
    require(RegExp(r'^tx_[A-Za-z0-9_-]{22}$').hasMatch(tx), 'request_invalid');
    host.atomic('$directory/aborted', utf8.encode(tx), mode: 0x180);
    if (!exists(undo)) return;
    final record = readJson(undo, 1114112);
    if (record['transaction'] != tx) return;
    await _write(configuration, record['configuration'] as String);
    await _lifecycle(record['running'] == true ? 'restart' : 'stop');
    if (record['running'] == true) await _verifyConfiguration();
    await run([
      'systemctl',
      record['enabled'] == true ? 'enable' : 'disable',
      unit,
    ]);
    unlink(undo);
  }

  Future<void> install({bool update = false}) async {
    if (installed && !update) return;
    if (update) require(installed, 'binary_missing');
    final panel = readText('$nodeProgram/bundle/VERSION', 128).trim();
    final release = await verifiedRelease(engine, panel, targetPlatform());
    if (exists('$slots/current')) {
      final path = resolved('$slots/current');
      require(parent(path) == slots, 'unsafe_file');
      if (readJson('$path/artifact.json')['version'] == release.tag) return;
    }
    final files = await artifactFiles(
      engine,
      release.tag,
      release.url,
      release.sha,
      targetPlatform(),
    );
    if (engine == 'amneziawg') {
      for (final tool in ['ip', 'nft']) {
        final found = await command([
          'sh',
          '-c',
          'command -v $tool >/dev/null',
        ], check: false);
        require(found.exitCode == 0, 'core_dependencies_missing');
      }
      files[engine] = await temporary(
        '/var/tmp',
        'sky-ui-node-build-',
        (work) =>
            buildAwg(files.remove('source.tar.gz')!, work, release.tag, null),
      );
      final receipt = object(jsonDecode(utf8.decode(files['artifact.json']!)))
        ..['binarySha256'] = digest(files[engine]!);
      files['artifact.json'] = Uint8List.fromList(
        utf8.encode(jsonEncode(receipt)),
      );
    }
    await activateVerifiedArtifact(release.tag, files, update: update);
  }

  /// Activate previously verified files; callers own the serialized node lock.
  Future<void> activateVerifiedArtifact(
    String version,
    Map<String, Uint8List> files, {
    bool update = false,
  }) async {
    require(
      coreTagPattern.hasMatch(version) &&
          files[engine] != null &&
          files['artifact.json'] != null,
      'archive_invalid',
    );
    host.mkdir('$nodeProgram/cores', mode: 0x1ed);
    host.mkdir(slots, mode: 0x1ed);
    final slot = '$slots/$version-${digest(files[engine]!).substring(0, 16)}';
    host.mkdir(slot, mode: 0x1ed);
    for (final file in files.entries) {
      require(
        [engine, 'LICENSE', 'artifact.json'].contains(file.key),
        'archive_invalid',
      );
      host.atomic(
        '$slot/${file.key}',
        file.value,
        mode: file.key == engine ? 0x1ed : 0x1a4,
      );
    }
    await validate(configuration, executable: '$slot/$engine');
    String? previous;
    if (exists('$slots/current'))
      previous = resolved('$slots/current');
    else if (engine == 'mihomo' && installed) {
      final old = host.read('$nodeProgram/mihomo', limit: 100 * 1024 * 1024);
      previous = '$slots/imported-${digest(old).substring(0, 16)}';
      host.mkdir(previous, mode: 0x1ed);
      host.atomic('$previous/mihomo', old, mode: 0x1ed);
      atomicJson('$previous/artifact.json', {
        'coreId': engine,
        'version': null,
        'binarySha256': digest(old),
      }, mode: 0x1a4);
    }
    final running = await active(unit);
    final bindings = nodeConfigurationBindings(
      engine,
      loadYaml(readText(configuration, 524288)) as Map,
    );
    final autoStart =
        !update &&
        !running &&
        (bindings.tcp.isNotEmpty || bindings.udp.isNotEmpty);
    atomicJson('$slots/activation.json', {
      'previous': previous,
      'candidate': slot,
      'running': running,
      'autoStart': autoStart,
    }, mode: 0x180);
    try {
      switchLink('$slots/current', slot);
      if (engine == 'mihomo')
        switchLink('$nodeProgram/mihomo', '$slots/current/mihomo');
      if (running || autoStart) {
        await _lifecycle('restart');
        await _verify(bindings.tcp, bindings.udp);
        if (autoStart) await run(['systemctl', 'enable', unit]);
      }
      atomicJson('$slots/previous.json', {'path': previous}, mode: 0x1a4);
      unlink('$slots/removed.json');
      unlink('$slots/activation.json');
      for (final entry in Directory(slots).listSync(followLinks: false)) {
        if (entry is! Directory || entry.path == slot || entry.path == previous)
          continue;
        final name = basename(entry.path);
        if (RegExp(r'^(?:v[0-9]+\.[0-9]+\.[0-9]+|imported)-[a-f0-9]{16}$')
            .hasMatch(name))
          host.deleteTree(entry.path);
      }
    } on Object {
      if (autoStart) await run(['systemctl', 'disable', '--now', unit]);
      if (previous != null)
        switchLink('$slots/current', previous);
      else
        unlink('$slots/current');
      if (running && previous != null) {
        await _lifecycle('restart');
        await _verifyConfiguration();
      }
      unlink('$slots/activation.json');
      rethrow;
    }
  }

  Future<void> remove() async {
    await run(['systemctl', 'disable', '--now', unit]);
    require(!await active(unit), 'service_stop_timeout');
    host.mkdir('$nodeProgram/cores', mode: 0x1ed);
    host.mkdir(slots, mode: 0x1ed);
    unlink('$slots/current');
    if (engine == 'mihomo') unlink('$nodeProgram/mihomo');
    if (exists(slots)) {
      for (final entry in Directory(slots).listSync(followLinks: false)) {
        if (entry is Directory &&
            RegExp(r'^(?:v[0-9]+\.[0-9]+\.[0-9]+|imported)-[a-f0-9]{16}$')
                .hasMatch(basename(entry.path)))
          host.deleteTree(entry.path);
      }
      unlink('$slots/previous.json');
      atomicJson('$slots/removed.json', {
        'coreId': engine,
        'removed': true,
      }, mode: 0x1a4);
    }
  }
}

Set<int> nodePorts(Object? input) {
  require(input is List && input.length <= 4096, 'request_invalid');
  require(
    (input as List).every((p) => p is int && p >= 1024 && p <= 65535),
    'request_invalid',
  );
  return input.cast<int>().toSet();
}

Future<void> nodeMain(List<String> args) async {
  final operation = parseNodeCommand(args);
  host.trusted(nodeProgram, directory: true);
  host.trusted(nodeRoot, directory: true);
  final lock = HostLock('/run/lock/sky-ui-node.lock');
  try {
    await lock.acquire();
    if (operation.verb == 'ports') {
      final ports = <int>{};
      for (final flag in ['-Hltn', '-Hlun']) {
        final lines = await run(['ss', flag]);
        for (final line in lines.split('\n')) {
          final fields = line.trim().split(RegExp(r'\s+'));
          if (fields.length < 5) continue;
          final port = int.tryParse(fields[3].split(':').last);
          if (port != null && port > 0 && port <= 65535) ports.add(port);
        }
      }
      stdout.writeln(jsonEncode(ports.toList()..sort()));
      return;
    }
    if (operation.verb == 'inventory') {
      final values = <Map<String, Object?>>[];
      for (final id in nodeEngines) {
        final engine = NodeEngine(id);
        await engine.initialize();
        values.add(await engine.inspect());
      }
      stdout.writeln(jsonEncode(values));
      return;
    }
    final engine = NodeEngine(operation.engine);
    await engine.initialize();
    switch (operation.verb) {
      case 'inspect':
      case 'diagnose':
        stdout.writeln(
          jsonEncode(
            await engine.inspect(diagnose: operation.verb == 'diagnose'),
          ),
        );
      case 'probe':
        final request = object(jsonDecode(await _input()));
        final observation = request['remote'] == true
            ? <String, Object?>{'listeners': <Object>[]}
            : await engine.inspect(diagnose: true, validateNative: false);
        final allowed = <int>{
          for (final listener in observation['listeners'] as List)
            if (listener['udp'] == false) listener['port'] as int,
        };
        stdout.writeln(
          jsonEncode(await probeNodeNetwork(request, localTcpPorts: allowed)),
        );
      case 'status':
        stdout.writeln((await engine.inspect())['state']);
      case 'logs':
        stdout.write(
          await run([
            'journalctl',
            '--unit',
            engine.unit,
            '--lines',
            '60',
            '--output',
            'short-iso',
            '--no-pager',
          ]),
        );
      case 'install':
      case 'update':
        await engine.install(update: operation.verb == 'update');
        stdout.writeln(jsonEncode(await engine.inspect()));
      case 'remove':
        await engine.remove();
        stdout.writeln(jsonEncode(await engine.inspect()));
      case 'start':
      case 'stop':
      case 'restart':
        require(engine.installed, 'binary_missing');
        await engine._lifecycle(operation.verb);
        if (operation.verb != 'stop') {
          final bindings = nodeConfigurationBindings(
            engine.engine,
            loadYaml(readText(engine.configuration, 524288)) as Map,
          );
          await engine._verify(bindings.tcp, bindings.udp);
        }
        await run([
          'systemctl',
          operation.verb == 'stop' ? 'disable' : 'enable',
          engine.unit,
        ]);
        stdout.writeln((await engine.inspect())['state']);
      case 'validate':
        final candidate = await _input();
        await engine._write('${engine.directory}/candidate.json', candidate);
        try {
          await engine.validate('${engine.directory}/candidate.json');
        } finally {
          unlink('${engine.directory}/candidate.json');
        }
      case 'deploy':
        await engine.deploy(object(jsonDecode(await _input())));
      case 'rollback':
        await engine.rollback((await _input()).trim());
    }
  } finally {
    lock.close();
  }
}
