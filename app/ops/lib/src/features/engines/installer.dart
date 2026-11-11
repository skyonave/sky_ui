import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:yaml/yaml.dart';

import '../../platform/host.dart';
import '../../shared/archives.dart';
import '../../shared/artifacts.dart';
import '../../shared/progress.dart';
import '../backups/backups.dart';
import '../storage/retention.dart';
import 'amnezia.dart';

String? existingMihomo() {
  final link = '$cores/mihomo/current';
  if (!exists(link)) return null;
  require(isLink(link), 'unsafe_file');
  final target = resolved(link);
  require(
    parent(target) == '$cores/mihomo' ||
        basename(target) == 'bin' && parent(parent(target)) == releases,
    'unsafe_file',
  );
  host.trusted(target, directory: true);
  host.trusted('$target/mihomo');
  return '$target/mihomo';
}

Future<String?> prepareMihomo(
  String panel,
  String platform,
  String output,
) async {
  const root = '$cores/mihomo';
  if (exists('$root/removed.json')) {
    host.trusted('$root/removed.json');
    final marker = readJson('$root/removed.json');
    require(
      marker.length == 2 &&
          marker['coreId'] == 'mihomo' &&
          marker['removed'] == true,
      'unsafe_file',
    );
    return null;
  }
  final existing = existingMihomo();
  if (existing != null && parent(parent(existing)) == root) return existing;
  Map<String, Uint8List> files;
  if (existing == null) {
    final release = await verifiedRelease('mihomo', panel, platform);
    files = await artifactFiles(
      'mihomo',
      release.tag,
      release.url,
      release.sha,
      platform,
    );
  } else {
    final binary = host.read(existing);
    host.trusted('${parent(parent(existing))}/licenses/mihomo.LICENSE');
    files = {
      'mihomo': binary,
      'LICENSE': host.read(
        '${parent(parent(existing))}/licenses/mihomo.LICENSE',
      ),
      'artifact.json': Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'coreId': 'mihomo',
            'version': null,
            'platform': platform,
            'binarySha256': digest(binary),
            'source': 'legacy-panel-bundle',
          }),
        ),
      ),
    };
  }
  require(!exists(output), 'unsafe_file');
  host.mkdir(output);
  for (final entry in files.entries)
    host.atomic(
      '$output/${entry.key}',
      entry.value,
      mode: entry.key == 'mihomo' ? 0x1ed : 0x1a4,
    );
  return '$output/mihomo';
}

Future<void> validateMihomo(
  String binary,
  String configuration,
  String directory,
) async {
  host.trusted(binary);
  final args = [
    'runuser',
    '-u',
    'sky-ui-core',
    '-g',
    'sky-ui',
    '--',
    'env',
    'SAFE_PATHS=/var/lib/sky-ui-certificates',
    binary,
  ];
  final version = await run([...args, '-v']);
  final receipt = '${parent(binary)}/artifact.json';
  if (exists(receipt)) {
    host.trusted(receipt);
    final expected = readJson(receipt)['version'] as String?;
    if (expected != null)
      require(
        RegExp('\\bv?${RegExp.escape(expected.substring(1))}\\b')
            .hasMatch(version),
        'binary_version_mismatch',
      );
  }
  await run([...args, '-t', '-d', directory, '-f', configuration]);
}

String activateMihomo(String prepared) {
  const root = '$cores/mihomo';
  final installed = existingMihomo();
  if (installed != null && parent(parent(installed)) == root) return installed;
  final files = <String, Uint8List>{
    for (final name in ['mihomo', 'LICENSE', 'artifact.json'])
      name: host.read('$prepared/$name'),
  };
  for (final name in files.keys) host.trusted('$prepared/$name');
  final receipt = object(jsonDecode(utf8.decode(files['artifact.json']!))),
      sha = digest(files['mihomo']!);
  final version = receipt['version'] as String?;
  require(
    receipt['coreId'] == 'mihomo' && receipt['binarySha256'] == sha,
    'release_checksum_failed',
  );
  require(
    version != null
        ? coreTagPattern.hasMatch(version)
        : receipt['source'] == 'legacy-panel-bundle',
    'binary_invalid',
  );
  host.trusted(root, directory: true);
  final slot = '$root/${version ?? 'imported'}-${sha.substring(0, 16)}';
  if (exists(slot)) {
    host.trusted(slot, directory: true);
    host.trusted('$slot/mihomo');
    require(
      digest(host.read('$slot/mihomo')) == sha,
      'release_checksum_failed',
    );
  } else {
    host.mkdir(slot);
    for (final entry in files.entries)
      host.atomic(
        '$slot/${entry.key}',
        entry.value,
        mode: entry.key == 'mihomo' ? 0x1ed : 0x1a4,
      );
  }
  switchLink('$root/current', slot);
  if (installed == null && !exists('$root/retention.json'))
    atomicJson('$root/retention.json', {
      'current': slot,
      'previous': null,
    }, mode: 0x180);
  return '$slot/mihomo';
}

Future<void> validateEngine(
  String core,
  String binary, {
  String? configuration,
}) async {
  configuration ??=
      '$dataRoot/cores/$core/${core == 'mihomo' ? 'config.yaml' : 'config.json'}';
  if (core == 'mihomo')
    return validateMihomo(
      File(binary).resolveSymbolicLinksSync(),
      configuration,
      '$dataRoot/cores/mihomo',
    );
  if (core == 'amneziawg') {
    await run([
      'sh',
      '-c',
      'command -v nft >/dev/null && command -v ip >/dev/null',
    ]);
    loadAwg(configuration);
    return;
  }
  await run([
    'runuser',
    '-u',
    'sky-ui-$core',
    '--',
    if (core == 'xray') ...['env', 'XRAY_LOCATION_ASSET=$dataRoot/cores/xray'],
    binary,
    ...core == 'xray'
        ? ['run', '-test', '-config', configuration]
        : ['check', '-c', configuration],
  ]);
}

Future<void> awaitEngineReady(String core, {String? version}) async {
  if (core == 'mihomo') return controllerReady(environment(), version: version);
  final value = readJson('$dataRoot/cores/$core/config.json', 4 * 1024 * 1024),
      expected = <String>{};
  for (final v
      in (value[core == 'amneziawg' ? 'interfaces' : 'inbounds'] as List? ??
          [])) {
    final i = object(v), port = i['listen_port'] ?? i['port'];
    final udp =
        core == 'amneziawg' ||
        ['hysteria2', 'tuic'].contains(i['type']) ||
        i['network'] == 'udp';
    expected.add('$port/$udp');
    if ((i['type'] ?? i['protocol']) == 'shadowsocks')
      expected.add('$port/true');
  }
  final unit = 'sky-ui-$core.service',
      end = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(end)) {
    if (await active(unit)) {
      final group = (await run([
        'systemctl',
        'show',
        '--property=ControlGroup',
        '--value',
        unit,
      ])).trim();
      require(group == '/system.slice/$unit', 'service_failed');
      try {
        final paths = [
          '/sys/fs/cgroup$group/cgroup.procs',
          '/sys/fs/cgroup/systemd$group/cgroup.procs',
        ];
        final path = paths.firstWhere((p) => File(p).existsSync());
        final pids = File(path).readAsStringSync().trim().split(RegExp(r'\s+'));
        final inodes = <String>{};
        for (final pid in pids)
          for (final fd in Directory(
            '/proc/$pid/fd',
          ).listSync(followLinks: false)) {
            final target = Link(fd.path).targetSync();
            if (target.startsWith('socket:['))
              inodes.add(target.substring(8, target.length - 1));
          }
        final found = <String>{};
        for (final family in ['tcp', 'tcp6', 'udp', 'udp6'])
          for (final line in File(
            '/proc/net/$family',
          ).readAsLinesSync().skip(1)) {
            final fields = line.trim().split(RegExp(r'\s+'));
            if (inodes.contains(fields[9]) &&
                (family.startsWith('udp') || fields[3] == '0A'))
              found.add(
                '${int.parse(fields[1].split(':')[1], radix: 16)}/${family.startsWith('udp')}',
              );
          }
        if (expected.every(found.contains) &&
            (core != 'amneziawg' ||
                (value['interfaces'] as List).every(
                  (i) => exists('/sys/class/net/${i['name']}'),
                )))
          return;
      } on FileSystemException {
        /* A process may exit between proc reads. */
      }
    }
    await sleep(200);
  }
  throw const OpsError('listener_not_ready');
}

Future<void> restartReady(String core, {String? version}) async {
  await command([
    'systemctl',
    'reset-failed',
    'sky-ui-$core.service',
  ], check: false);
  await run(['systemctl', 'restart', 'sky-ui-$core.service']);
  await awaitEngineReady(core, version: version);
}

bool hasManagedListeners(String core, Map config) => switch (core) {
  'mihomo' => (config['listeners'] as List? ?? []).any(
    (listener) =>
        listener is Map &&
        (listener['name'] as String? ?? '').startsWith('sky-ui/c_'),
  ),
  'amneziawg' => (config['interfaces'] as List? ?? []).isNotEmpty,
  _ => (config['inbounds'] as List? ?? []).any(
    (inbound) =>
        inbound is Map &&
        (inbound['tag'] as String? ?? '').startsWith('sky-c_'),
  ),
};

const goToolchains = {
  'linux-amd64': (
    'go1.27.3.linux-amd64.tar.gz',
    '65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40',
  ),
  'linux-arm64': (
    'go1.27.3.linux-arm64.tar.gz',
    'a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49',
  ),
};
Future<Uint8List> buildAwg(
  Uint8List source,
  String work,
  String tag,
  Reporter? reporter,
) async {
  require(
    await freeBytes(work) >= 1024 * 1024 * 1024,
    'core_build_space_required',
  );
  final user = await account('sky-ui-build');
  // Keep the outer workspace root-owned so abandoned work can be reclaimed
  // safely; only the contained build tree belongs to the compiler account.
  host.mkdir(work);
  host.mkdir('$work/build');
  work = '$work/build';
  host.mkdir('$work/source');
  final files = tarFiles(
    source,
    limit: 64 * 1024 * 1024,
    maxFiles: 8192,
    directories: true,
  );
  final roots = files.keys.map((p) => p.split('/').first).toSet();
  require(roots.length == 1, 'archive_invalid');
  void putTree(
    Map<String, Uint8List> files,
    String root, {
    bool strip = false,
    bool executable = false,
  }) {
    for (final entry in files.entries) {
      final name = strip
          ? entry.key.substring(entry.key.indexOf('/') + 1)
          : entry.key;
      require(safeMember(name), 'archive_invalid');
      var dir = root;
      for (final p in name.split('/').take(name.split('/').length - 1)) {
        dir = '$dir/$p';
        if (!exists(dir)) host.mkdir(dir);
      }
      host.atomic(
        '$root/$name',
        entry.value,
        mode: executable && RegExp(r'/(bin|pkg/tool)/').hasMatch('/$name')
            ? 0x1ed
            : 0x1a4,
      );
    }
  }

  putTree(files, '$work/source', strip: true);
  host.atomic(
    '$work/source/version.go',
    utf8.encode(
      'package main\nconst Version = ${jsonEncode(tag.substring(1))}\n',
    ),
    mode: 0x1a4,
  );
  await run(['chown', '-R', '${user.uid}:${user.gid}', work]);
  final sdk = goToolchains[targetPlatform()]!;
  reporter?.stage('toolchain', {
    'bytesReceived': 0,
    'bytesTotal': null,
    'artifact': sdk.$1,
  });
  final bytes = await httpBytes(
    'https://go.dev/dl/${sdk.$1}',
    96 * 1024 * 1024,
    progress: (n) => reporter?.transfer(n, null, sdk.$1, 'toolchain'),
    size: (n) => reporter?.stage('toolchain', {'bytesTotal': n}),
  );
  require(digest(bytes) == sdk.$2, 'release_checksum_failed');
  // Consume each SDK entry before advancing to keep small VPS memory bounded.
  var compilerBytes = 0, compilerFiles = 0;
  final compilerNames = <String>{};
  TarDecoder().decodeStream(
    GZipDecoder().decodeLazy(InputMemoryStream(bytes), verify: true),
    verify: true,
    keepEntries: false,
    callback: (entry) {
      var name = entry.name;
      if (name.endsWith('/')) name = name.substring(0, name.length - 1);
      require(
        safeMember(name) &&
            (name == 'go' || name.startsWith('go/')) &&
            !entry.isSymbolicLink &&
            compilerNames.add(name) &&
            ++compilerFiles <= 20000,
        'archive_invalid',
      );
      if (entry.isDirectory) return;
      compilerBytes += entry.size;
      require(compilerBytes <= 400 * 1024 * 1024, 'archive_too_large');
      var directory = work;
      for (final part in name.split('/').take(name.split('/').length - 1)) {
        directory = '$directory/$part';
        if (!exists(directory)) host.mkdir(directory);
      }
      host.atomic(
        '$work/$name',
        entry.readBytes()!,
        mode: entry.mode & 0x49 != 0 ? 0x1ed : 0x1a4,
      );
    },
  );
  host.mkdir('$work/tmp', mode: 0x1c0, uid: user.uid, gid: user.gid);
  final args = [
    'nice',
    '-n',
    '10',
    'runuser',
    '-u',
    'sky-ui-build',
    '--',
    '/usr/bin/env',
    'HOME=$work',
    'GOCACHE=$work/cache',
    'GOPATH=$work/gopath',
    'TMPDIR=$work/tmp',
    'GOTMPDIR=$work/tmp',
    'GOMODCACHE=$work/modules',
    'GOTOOLCHAIN=local',
    'CGO_ENABLED=0',
    'GOPROXY=https://proxy.golang.org,direct',
    'GOSUMDB=sum.golang.org',
    'GOMAXPROCS=1',
    'GOMEMLIMIT=128MiB',
    'GOFLAGS=-p=1',
    '$work/go/bin/go',
    '-C',
    '$work/source',
    'build',
    '-trimpath',
    '-o',
    '$work/amneziawg',
    '.',
  ];
  if (reporter != null) {
    reporter.stage('build', {
      'bytesReceived': null,
      'bytesTotal': null,
      'artifact': null,
      'command': 'go build',
    });
    try {
      await runInstaller(args, reporter, timeout: const Duration(minutes: 8));
    } on InstallerFailure catch (e) {
      reporter.progress['exitCode'] = e.exitCode;
      throw const OpsError('core_build_failed');
    }
  } else {
    await run(args, timeout: const Duration(minutes: 8));
  }
  return host.read('$work/amneziawg', limit: 100 * 1024 * 1024);
}

Future<Map<String, dynamic>> changeEngine(
  String action,
  String core,
  String? tag,
  int gid, {
  Reporter? reporter,
  Future<void> Function()? beforeActivation,
  Fetch? fetch,
  Future<Uint8List> Function(Uint8List, String, String, Reporter?)? compileAwg,
}) async {
  require(engineIds.contains(core), 'core_unsupported');
  final root = '$cores/$core';
  host.trusted(root, directory: true);
  final unit = 'sky-ui-$core.service',
      instance =
          '$dataRoot/instances/${core == 'mihomo' ? 'primary' : core}.json';
  if (action == 'remove') {
    final slots = Directory(root)
        .listSync(followLinks: false)
        .where((e) => slotPattern.hasMatch(basename(e.path)))
        .toList();
    for (final slot in slots) {
      host.trusted(slot.path, directory: true);
      for (final file in Directory(slot.path).listSync(followLinks: false)) {
        require(
          [core, 'LICENSE', 'artifact.json'].contains(basename(file.path)),
          'unsafe_file',
        );
        host.trusted(file.path);
      }
    }
    final intent = core == 'mihomo'
        ? '$state/core-remove-intent.json'
        : '$state/engine-intent.json';
    atomicJson(
      intent,
      core == 'mihomo' ? {'core': core} : {'action': action, 'core': core},
      mode: 0x180,
    );
    await run(['systemctl', 'stop', unit]);
    require(!await active(unit), 'service_stop_timeout');
    unlink('$root/current');
    for (final slot in slots) host.deleteTree(slot.path);
    atomicJson('$root/removed.json', {
      'coreId': core,
      'removed': true,
    }, mode: 0x1a4);
    unlink('$root/previous.json');
    unlink(intent);
    return {'core': core, 'installed': false};
  }
  String? previous;
  if (exists('$root/current')) {
    require(isLink('$root/current'), 'unsafe_file');
    previous = resolved('$root/current');
    require(
      parent(previous) == root ||
          core == 'mihomo' &&
              basename(previous) == 'bin' &&
              parent(parent(previous)) == releases,
      'unsafe_file',
    );
    host.trusted(previous, directory: true);
  }
  require(
    (action == 'install') == (previous == null),
    action == 'install' ? 'core_already_installed' : 'binary_missing',
  );
  final selected = await verifiedRelease(
    core,
    panelVersion(),
    targetPlatform(),
    selected: tag,
    fetch: fetch,
  );
  require(selected.tag == tag, 'release_changed');
  Future<Uint8List> download(String url, int limit) async {
    final name = Uri.parse(url).pathSegments.last;
    reporter?.stage('download', {
      'bytesReceived': 0,
      'bytesTotal': null,
      'artifact': name,
    });
    if (fetch != null) return fetch(url, limit);
    return httpBytes(
      url,
      limit,
      progress: (n) => reporter?.transfer(n, null, name),
      size: (n) => reporter?.stage('download', {'bytesTotal': n}),
    );
  }

  final files = await artifactFiles(
    core,
    tag!,
    selected.url,
    selected.sha,
    targetPlatform(),
    fetch: download,
  );
  if (core == 'amneziawg') {
    files[core] = await temporary(
      '/var/tmp',
      'sky-ui-build-',
      (work) => (compileAwg ?? buildAwg)(
        files.remove('source.tar.gz')!,
        work,
        tag,
        reporter,
      ),
    );
    final receipt = object(jsonDecode(utf8.decode(files['artifact.json']!)));
    receipt['binarySha256'] = digest(files[core]!);
    files['artifact.json'] = Uint8List.fromList(
      utf8.encode(jsonEncode(receipt)),
    );
  }
  final slot = '$root/$tag-${digest(files[core]!).substring(0, 16)}';
  if (exists(slot)) host.trusted(slot, directory: true);
  host.mkdir(slot);
  for (final entry in files.entries) {
    require(
      [core, 'LICENSE', 'artifact.json'].contains(entry.key),
      'archive_invalid',
    );
    host.atomic(
      '$slot/${entry.key}',
      entry.value,
      mode: entry.key == core ? 0x1ed : 0x1a4,
    );
  }
  reporter?.stage('validate', {
    'bytesReceived': null,
    'bytesTotal': null,
    'artifact': null,
    'command': null,
  });
  await beforeActivation?.call();
  await validateEngine(core, '$slot/$core');
  final autoStart =
      action == 'install' &&
      (!exists(instance) ||
          readJson(instance, 65536)['desiredState'] != 'stopped') &&
      hasManagedListeners(
        core,
        core == 'mihomo'
            ? loadYaml(
                utf8.decode(
                  host.read(
                    '$dataRoot/cores/mihomo/config.yaml',
                    limit: 4 * 1024 * 1024,
                  ),
                ),
              ) as Map
            : readJson('$dataRoot/cores/$core/config.json', 4 * 1024 * 1024),
      );
  final running = await active(unit),
      intent = core == 'mihomo'
          ? '$state/update-intent.json'
          : '$state/engine-intent.json';
  atomicJson(
    intent,
    core == 'mihomo'
        ? {'path': previous, 'running': running, 'autoStart': autoStart}
        : {
            'action': action,
            'core': core,
            'previous': previous,
            'running': running,
            'autoStart': autoStart,
          },
    mode: 0x180,
  );
  try {
    reporter?.stage('activate');
    switchLink('$root/current', slot);
    if (running || autoStart) await restartReady(core, version: tag);
    unlink('$root/removed.json');
    unlink(intent);
  } on Object {
    if (autoStart && !running) await run(['systemctl', 'stop', unit]);
    if (previous != null)
      switchLink('$root/current', previous);
    else
      unlink('$root/current');
    if (running) await restartReady(core);
    unlink(intent);
    throw const OpsError('update_rolled_back');
  }
  recordRetention('core', previous, core);
  return {'core': core, 'version': tag, 'installed': true};
}
