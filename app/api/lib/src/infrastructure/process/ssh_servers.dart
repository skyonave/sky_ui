import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../application/access/records.dart';
import '../../application/configuration/relay_routes.dart';
import '../../shared/api_exception.dart';
import 'command_runner.dart';

/// Each host has its own private identity and explicitly pinned SSH host key.
class SshServers implements RelayTransport {
  SshServers(String dataDirectory, this.runner, {this.bundle})
    : directory = Directory('$dataDirectory/remote-servers');

  final Directory directory;
  final CommandRunner runner;
  final Directory? bundle;
  final _busy = <String>{};
  bool _adding = false;
  static const maximumNodes = 32;
  static final _id = RegExp(r'^node_[A-Za-z0-9_-]{22}$');
  static final _dns = RegExp(
    r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$',
  );
  static final _ed25519 = RegExp(
    r'^ssh-ed25519 (AAAAC3NzaC1lZDI1NTE5AAAAI[A-Za-z0-9+/]{43})$',
  );
  bool _validHost(String host) =>
      host.isNotEmpty &&
      host.length <= 253 &&
      (InternetAddress.tryParse(host) != null ||
          host.split('.').every(_dns.hasMatch));

  List<ServerNode> list() {
    if (!directory.existsSync()) return [];
    final nodes = [
      for (final entry in directory.listSync(followLinks: false))
        if (entry is Directory &&
            _id.hasMatch(
              entry.uri.pathSegments.where((v) => v.isNotEmpty).last,
            ) &&
            File('${entry.path}/node.json').existsSync())
          _read(entry.path),
    ];
    return nodes..sort((a, b) => a.name.compareTo(b.name));
  }

  @override
  Map<String, ServerNode> nodes() => {for (final node in list()) node.id: node};

  ServerNode _read(String path) => ServerNode.fromJson(
    jsonDecode(File('$path/node.json').readAsStringSync())
        as Map<String, dynamic>,
  );

  String _path(String id) {
    final path = '${directory.path}/$id';
    if (!_id.hasMatch(id) || !File('$path/node.json').existsSync()) {
      throw const ApiException('not_found', status: 404);
    }
    return path;
  }

  Future<ServerNode> add({
    required String name,
    required String host,
    required int port,
    required String hostKey,
    String? endpoint,
    String? relayAddress,
  }) async {
    name = name.trim();
    host = host.trim().toLowerCase();
    hostKey = hostKey.trim();
    endpoint = endpoint?.trim().toLowerCase();
    relayAddress = relayAddress?.trim();
    if (endpoint == '') endpoint = null;
    if (relayAddress == '') relayAddress = null;
    final ip = InternetAddress.tryParse(host);
    if (name.isEmpty ||
        name.length > 80 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
        !_validHost(host) ||
        (endpoint != null && !_validHost(endpoint)) ||
        (relayAddress != null &&
            InternetAddress.tryParse(relayAddress) == null) ||
        port < 1 ||
        port > 65535 ||
        !_ed25519.hasMatch(hostKey)) {
      throw const ApiException('server_invalid', status: 422);
    }
    if (ip != null) host = ip.address;
    if (_adding) throw const ApiException('server_busy', status: 409);
    _adding = true;
    Directory? staging;
    try {
      final nodes = list();
      if (nodes.any((node) => node.host == host && node.port == port)) {
        throw const ApiException('server_duplicate', status: 409);
      }
      if (nodes.length >= maximumNodes) {
        throw const ApiException('server_limit', status: 409);
      }
      await directory.create(recursive: true);
      staging = await directory.createTemp('.new-');
      final identity = '${staging.path}/identity';
      final result = await runner.run('/usr/bin/ssh-keygen', [
        '-q',
        '-t',
        'ed25519',
        '-N',
        '',
        '-C',
        'sky-ui-node',
        '-f',
        identity,
      ]);
      if (result.exitCode != 0) {
        throw const ApiException('server_key_failed', status: 500);
      }
      final publicKey = (await File('$identity.pub').readAsString()).trim();
      final id = newId('node');
      final node = ServerNode(
        id: id,
        name: name,
        host: host,
        port: port,
        publicKey: publicKey,
        endpoint: endpoint,
        relayAddress: relayAddress,
      );
      await File(
        '${staging.path}/known_hosts',
      ).writeAsString('sky-ui-node $hostKey\n', flush: true);
      await File(
        '${staging.path}/node.json',
      ).writeAsString(jsonEncode(node.toJson()), flush: true);
      await staging.rename('${directory.path}/$id');
      staging = null;
      return node;
    } finally {
      try {
        if (staging != null) await staging.delete(recursive: true);
      } finally {
        _adding = false;
      }
    }
  }

  Future<String> execute(String id, ServerOperation operation) async {
    final output = await _ssh(id, operation.name);
    if (operation != ServerOperation.logs &&
        !{
          'active',
          'inactive',
          'failed',
          'activating',
          'deactivating',
          'reloading',
          'maintenance',
          'refreshing',
        }.contains(output)) {
      throw const ApiException('server_operation_failed', status: 502);
    }
    return output;
  }

  @override
  Future<RelayState> inspect(String node) async {
    final output = await _ssh(node, 'inspect');
    final match = RegExp(
      r'^([a-f0-9]{64}) (active|inactive|failed)( 2)?$',
    ).firstMatch(output);
    if (match == null)
      throw const ApiException('route_node_protocol', status: 502);
    return RelayState(
      match[1]!,
      match[2] == 'active',
      extendedUdp: match[3] != null,
    );
  }

  @override
  Future<void> validate(String node, String configuration) async {
    await _ssh(node, 'validate', input: configuration);
  }

  @override
  Future<void> publish(
    String node,
    String transaction,
    String previous,
    String configuration,
    Set<int> ports,
    Set<int> udpPorts,
  ) async {
    await _ssh(
      node,
      'deploy',
      input:
          '$transaction\n$previous\n${ports.join(' ')}\n${udpPorts.join(' ')}\n$configuration',
    );
  }

  @override
  Future<void> rollback(String node, String transaction) async {
    await _ssh(node, 'rollback', input: '$transaction\n');
  }

  @override
  Future<void> probe(String node, String destination, int port) async {
    await _ssh(node, 'probe', input: '$destination\n$port\n');
  }

  Future<void> bootstrap(
    String id,
    String user,
    String key,
    String password,
  ) async {
    final path = _path(id);
    user = user.trim();
    key = key.replaceAll('\r\n', '\n').trim();
    if (!RegExp(r'^[a-z_][a-z0-9_-]{0,31}$').hasMatch(user) ||
        key.isEmpty == password.isEmpty ||
        key.length > 12288 ||
        key.isNotEmpty &&
            !RegExp(
              r'^-----BEGIN (?:OPENSSH |RSA |EC )?PRIVATE KEY-----\n[A-Za-z0-9+/=\n]+\n-----END (?:OPENSSH |RSA |EC )?PRIVATE KEY-----$',
            ).hasMatch(key) ||
        password.length > 512 ||
        RegExp(r'[\x00\r\n]').hasMatch(password)) {
      throw const ApiException('server_bootstrap_invalid', status: 422);
    }
    final native = runner;
    if (native is! NativeCommandRunner) {
      throw const ApiException('server_bootstrap_unavailable', status: 501);
    }
    final script = await _bootstrapScript(_read(path).publicKey);
    final temp = await Directory.systemTemp.createTemp('sky-ui-bootstrap-');
    try {
      final credential = File('${temp.path}/credential');
      await credential.writeAsString(
        '${key.isNotEmpty ? key : password}\n',
        flush: true,
      );
      final askpass = File('${temp.path}/askpass');
      if (password.isNotEmpty) {
        await askpass.writeAsString(
          '#!/bin/sh\nexec /bin/cat -- "\$SKY_UI_BOOTSTRAP_PASSWORD_FILE"\n',
        );
        final chmod = await runner.run('/usr/bin/chmod', [
          '0700',
          askpass.path,
        ]);
        if (chmod.exitCode != 0) {
          throw const ApiException('server_bootstrap_unavailable', status: 501);
        }
      }
      await _ssh(
        id,
        '/bin/bash -s',
        input: script,
        user: user,
        identity: key.isEmpty ? null : credential.path,
        passwordRunner: password.isEmpty
            ? null
            : NativeCommandRunner(
                environment: {
                  ...native.environment,
                  'SSH_ASKPASS': askpass.path,
                  'SSH_ASKPASS_REQUIRE': 'force',
                  'SKY_UI_BOOTSTRAP_PASSWORD_FILE': credential.path,
                },
              ),
      );
    } finally {
      await temp.delete(recursive: true);
    }
  }

  Future<String> _bootstrapScript(String key) async {
    final root = bundle?.path;
    if (root == null)
      throw const ApiException('server_bootstrap_unavailable', status: 501);
    final script = File('$root/deploy/install-server-node.sh');
    final compatibility = File('$root/compatibility/cores/mihomo.json');
    if (!await script.exists() || !await compatibility.exists()) {
      throw const ApiException('server_bootstrap_unavailable', status: 501);
    }
    final catalog = jsonDecode(await compatibility.readAsString()) as Map;
    final targets = <String, String>{};
    for (final release
        in (catalog['releases'] as List).reversed.whereType<Map>()) {
      final version = release['version'];
      if (release['verified'] != true ||
          version is! String ||
          !RegExp(r'^v[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(version))
        continue;
      for (final entry in {
        'x86_64': 'linux-amd64',
        'aarch64': 'linux-arm64',
      }.entries) {
        if (targets.containsKey(entry.key)) continue;
        final platform = (release['platforms'] as Map? ?? {})[entry.value];
        if (platform is! Map || platform['verified'] != true) continue;
        final asset = platform['asset'];
        final hash = platform['sha256'];
        if (asset is String &&
            RegExp(r'^[A-Za-z0-9._-]+\.gz$').hasMatch(asset) &&
            hash is String &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
          targets[entry.key] =
              "${entry.key}) url='https://github.com/MetaCubeX/mihomo/releases/download/$version/$asset'; hash='$hash' ;;";
        }
      }
    }
    final publicKey = key.split(' ').take(2).join(' ');
    if (targets.isEmpty || !_ed25519.hasMatch(publicKey)) {
      throw const ApiException('server_bootstrap_unavailable', status: 501);
    }
    return '''
set -euo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
case "\$(uname -m)" in
${targets.values.join('\n')}
*) exit 7 ;;
esac
tmp=\$(mktemp -d)
trap 'rm -f -- "\$tmp/"{installer,core.gz,mihomo,panel.pub}; rmdir -- "\$tmp"' EXIT
curl -fsSL --proto '=https' --tlsv1.2 --max-time 90 --max-filesize 100000000 -o "\$tmp/core.gz" "\$url"
printf '%s  %s\\n' "\$hash" "\$tmp/core.gz" | sha256sum -c - >/dev/null
gzip -dc -- "\$tmp/core.gz" > "\$tmp/mihomo"
chmod 0700 "\$tmp/mihomo"
printf '%s\\n' '$publicKey' > "\$tmp/panel.pub"
cat > "\$tmp/installer" <<'SKY_UI_NODE_INSTALLER'
${await script.readAsString()}
SKY_UI_NODE_INSTALLER
if (( EUID == 0 )); then
  /bin/bash "\$tmp/installer" "\$tmp/mihomo" "\$tmp/panel.pub"
else
  sudo -n /bin/bash "\$tmp/installer" "\$tmp/mihomo" "\$tmp/panel.pub"
fi
''';
  }

  Future<String> _ssh(
    String id,
    String operation, {
    String? input,
    String user = 'sky-ui-node',
    String? identity,
    NativeCommandRunner? passwordRunner,
  }) async {
    final path = _path(id);
    if (!_busy.add(id)) throw const ApiException('server_busy', status: 409);
    try {
      final node = _read(path);
      final arguments = [
        '-F',
        '/dev/null',
        input == null ? '-nT' : '-T',
        '-o',
        passwordRunner == null ? 'BatchMode=yes' : 'BatchMode=no',
        '-o',
        passwordRunner == null
            ? 'PreferredAuthentications=publickey'
            : 'PreferredAuthentications=password',
        '-o',
        'NumberOfPasswordPrompts=1',
        '-o',
        'ConnectTimeout=5',
        '-o',
        'ConnectionAttempts=1',
        '-o',
        'StrictHostKeyChecking=yes',
        '-o',
        'UpdateHostKeys=no',
        '-o',
        'HostKeyAlgorithms=ssh-ed25519',
        '-o',
        'GlobalKnownHostsFile=/dev/null',
        '-o',
        'UserKnownHostsFile=$path/known_hosts',
        '-o',
        'HostKeyAlias=sky-ui-node',
        '-o',
        'IdentitiesOnly=yes',
        '-o',
        'IdentityAgent=none',
        '-o',
        'ClearAllForwardings=yes',
        '-o',
        'LogLevel=ERROR',
        if (passwordRunner == null) ...['-i', identity ?? '$path/identity'],
        '-p',
        '${node.port}',
        '-l',
        user,
        '--',
        node.host,
        operation,
      ];
      final transport = passwordRunner ?? runner;
      final result = input != null && transport is NativeCommandRunner
          ? await transport.runWithInput(
              '/usr/bin/ssh',
              arguments,
              input: input,
              timeout: operation == '/bin/bash -s'
                  ? const Duration(minutes: 3)
                  : const Duration(seconds: 65),
            )
          : await transport.run(
              '/usr/bin/ssh',
              arguments,
              timeout: const Duration(seconds: 40),
            );
      if (result.exitCode != 0) {
        throw ApiException(
          operation == '/bin/bash -s' && result.exitCode == 7
              ? 'server_bootstrap_arch'
              : result.exitCode == 255
              ? 'server_ssh_failed'
              : 'server_operation_failed',
          status: 502,
        );
      }
      return result.output.trim();
    } finally {
      _busy.remove(id);
    }
  }

  Future<void> remove(String id) async {
    final path = _path(id);
    if (!_busy.add(id)) throw const ApiException('server_busy', status: 409);
    try {
      final retired = await Directory(
        path,
      ).rename('${directory.path}/${newId('.removed')}');
      await retired.delete(recursive: true);
    } finally {
      _busy.remove(id);
    }
  }
}
