import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../application/access/records.dart';
import '../../application/configuration/relay_routes.dart';
import '../../shared/api_exception.dart';
import 'command_runner.dart';
import 'node_bootstrap_catalog.dart';
import 'node_readiness_cache.dart';

/// Each host has its own private identity and explicitly pinned SSH host key.
class SshServers implements EngineRelayTransport, CachedRelayReadiness {
  SshServers(String dataDirectory, this.runner, {this.bundle})
    : directory = Directory('$dataDirectory/remote-servers');

  final Directory directory;
  final CommandRunner runner;
  final Directory? bundle;
  final _busy = <String>{};
  final _legacyNodes = <String>{};
  final _inventories = <String, Future<List<Map<String, Object?>>>>{};
  late final _readiness = NodeReadinessCache(
    fetch: _readEngineInventory,
    available: (node) => !_busy.contains(node),
  );

  @override
  Map<String, String> cachedReadiness(
    Iterable<({String node, String engine})> engines,
  ) => _readiness.read(engines);
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
    // Accept the complete public-key line, including its optional comment.
    if (!hostKey.contains('\n') && !hostKey.contains('\r')) {
      hostKey = hostKey.split(RegExp(r'[ \t]+')).take(2).join(' ');
    }
    endpoint = endpoint?.trim().toLowerCase();
    relayAddress = relayAddress?.trim();
    if (endpoint == '') endpoint = null;
    if (relayAddress == '') relayAddress = null;
    final ip = InternetAddress.tryParse(host);
    final errors = <String, String>{};
    if (name.isEmpty ||
        name.length > 80 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name))
      errors['name'] = 'name';
    if (!_validHost(host)) errors['host'] = 'host';
    if (endpoint != null && !_validHost(endpoint)) errors['endpoint'] = 'host';
    if (relayAddress != null && InternetAddress.tryParse(relayAddress) == null)
      errors['relayAddress'] = 'ip';
    if (port < 1 || port > 65535) errors['port'] = 'port';
    if (!_ed25519.hasMatch(hostKey)) errors['hostKey'] = 'hostKey';
    if (errors.isNotEmpty) {
      throw ApiException('server_invalid', status: 422, fields: errors);
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

  Future<String> execute(
    String id,
    ServerOperation operation, {
    String engine = 'mihomo',
  }) async {
    _engine(engine);
    String output;
    try {
      output = await _ssh(id, 'v3:${operation.name}:$engine');
    } on ApiException catch (error) {
      if (engine != 'mihomo' || error.code != 'server_upgrade_required')
        rethrow;
      output = await _ssh(id, operation.name);
    }
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

  static void _engine(String value) {
    if (!{'mihomo', 'sing-box', 'xray', 'amneziawg'}.contains(value))
      throw const ApiException('core_unsupported', status: 422);
  }

  Future<List<Map<String, Object?>>> engineInventory(String node) async {
    final values = await _readEngineInventory(node);
    if (!_busy.contains(node)) _readiness.observe(node, values);
    return values;
  }

  Future<List<Map<String, Object?>>> _readEngineInventory(String node) {
    final existing = _inventories[node];
    if (existing != null) return existing;
    late final Future<List<Map<String, Object?>>> pending;
    pending = _loadEngineInventory(node).whenComplete(() {
      if (identical(_inventories[node], pending)) _inventories.remove(node);
    });
    _inventories[node] = pending;
    return pending;
  }

  Future<List<Map<String, Object?>>> _loadEngineInventory(String node) async {
    final output = await _ssh(node, 'v3:inventory');
    try {
      final values = jsonDecode(output) as List;
      if (values.length != 4) throw const FormatException();
      _legacyNodes.remove(node);
      return [
        for (final value in values) Map<String, Object?>.from(value as Map),
      ];
    } on Object {
      throw const ApiException('route_node_protocol', status: 502);
    }
  }

  Future<void> installEngine(String node, String engine) async {
    _engine(engine);
    await _ssh(node, 'v3:install:$engine');
  }

  Future<void> updateEngine(String node, String engine) async {
    _engine(engine);
    await _ssh(node, 'v3:update:$engine');
  }

  Future<void> removeEngine(String node, String engine) async {
    _engine(engine);
    await _ssh(node, 'v3:remove:$engine');
  }

  @override
  Future<Set<int>> occupiedPorts(String node) async {
    try {
      final result = jsonDecode(await _ssh(node, 'v3:ports'));
      if (result is! List ||
          result.length > 65535 ||
          result.any((p) => p is! int || p < 1 || p > 65535))
        throw const FormatException();
      return result.cast<int>().toSet();
    } on ApiException {
      rethrow;
    } on Object {
      throw const ApiException('route_node_protocol', status: 502);
    }
  }

  Future<Map<String, dynamic>> diagnose(
    String node,
    String engine, {
    Future<void>? cancellation,
  }) async {
    _engine(engine);
    return _nodeJson(
      await _ssh(node, 'v3:diagnose:$engine', cancellation: cancellation),
    );
  }

  Future<Map<String, dynamic>> diagnosticNetwork(
    String node,
    String engine,
    Map<String, Object?> request, {
    Future<void>? cancellation,
  }) async {
    _engine(engine);
    return _nodeJson(
      await _ssh(
        node,
        'v3:probe:$engine',
        input: jsonEncode(request),
        cancellation: cancellation,
      ),
    );
  }

  Map<String, dynamic> _nodeJson(String value) {
    try {
      return Map<String, dynamic>.from(jsonDecode(value) as Map);
    } on Object {
      throw const ApiException('route_node_protocol', status: 502);
    }
  }

  @override
  Future<RelayState> inspectEngine(String node, String engine) async {
    _engine(engine);
    Map<String, dynamic> value;
    try {
      value = _nodeJson(await _ssh(node, 'v3:inspect:$engine'));
    } on ApiException catch (error) {
      if (engine != 'mihomo' || error.code != 'server_upgrade_required')
        rethrow;
      _legacyNodes.add(node);
      return inspect(node);
    }
    _legacyNodes.remove(node);
    final hash = value['hash'];
    if (hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        value['protocol'] != 3)
      throw const ApiException('route_node_protocol', status: 502);
    return RelayState(
      hash,
      value['state'] == 'active',
      extendedUdp: true,
      installed: value['installed'] == true,
      engineScoped: true,
    );
  }

  @override
  Future<void> validateEngine(
    String node,
    String engine,
    String configuration,
  ) async {
    _engine(engine);
    if (engine == 'mihomo' && _legacyNodes.contains(node))
      return validate(node, configuration);
    await _ssh(node, 'v3:validate:$engine', input: configuration);
  }

  @override
  Future<void> publishEngine(
    String node,
    String engine,
    String transaction,
    String previous,
    String configuration,
    Set<int> ports,
    Set<int> udpPorts,
  ) async {
    _engine(engine);
    if (engine == 'mihomo' && _legacyNodes.contains(node))
      return publish(
        node,
        transaction,
        previous,
        configuration,
        ports,
        udpPorts,
      );
    await _ssh(
      node,
      'v3:deploy:$engine',
      input: jsonEncode({
        'transaction': transaction,
        'previous': previous,
        'configuration': configuration,
        'tcp': ports.toList(),
        'udp': udpPorts.toList(),
      }),
    );
  }

  @override
  Future<void> rollbackEngine(
    String node,
    String engine,
    String transaction,
  ) async {
    _engine(engine);
    try {
      await _ssh(node, 'v3:rollback:$engine', input: '$transaction\n');
    } on ApiException catch (error) {
      if (engine != 'mihomo' || error.code != 'server_upgrade_required')
        rethrow;
      await rollback(node, transaction);
    }
  }

  /// The advertised address affects subscriptions, not the pinned SSH identity.
  Future<void> updateEndpoint(String id, String endpoint) async {
    await updateDetails(id, endpoint: endpoint);
  }

  /// Metadata edits retain the pinned SSH identity and existing route references.
  Future<void> updateDetails(
    String id, {
    String? name,
    String? endpoint,
  }) async {
    final path = _path(id);
    final previous = _read(path);
    name = (name ?? previous.name).trim();
    endpoint = endpoint ?? previous.endpoint ?? '';
    endpoint = endpoint.trim().toLowerCase();
    final errors = <String, String>{
      if (name.isEmpty ||
          name.length > 80 ||
          name.contains(RegExp(r'[\x00-\x1f\x7f]')))
        'name': 'name',
      if (endpoint.isNotEmpty && !_validHost(endpoint)) 'endpoint': 'host',
    };
    if (errors.isNotEmpty) {
      throw ApiException('server_invalid', status: 422, fields: errors);
    }
    final value = ServerNode(
      id: previous.id,
      name: name,
      host: previous.host,
      port: previous.port,
      publicKey: previous.publicKey,
      relayAddress: previous.relayAddress,
      endpoint: endpoint.isEmpty ? null : endpoint,
    );
    final staged = File('$path/node.json.tmp');
    await staged.writeAsString(jsonEncode(value.toJson()), flush: true);
    await staged.rename('$path/node.json');
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
    // Legacy intents keep their original undo location after a node upgrade.
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
    final version = (await File('$root/VERSION').readAsString()).trim();
    if (!RegExp(
      r'^[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?$',
    ).hasMatch(version))
      throw const ApiException('server_bootstrap_unavailable', status: 501);
    final catalog = Map<String, dynamic>.from(
      jsonDecode(await compatibility.readAsString()) as Map,
    );
    final targets = {
      for (final entry in selectNodeBootstrapAssets(catalog, version).entries)
        entry.key:
            "${entry.key}) url='https://github.com/MetaCubeX/mihomo/releases/download/${entry.value.version}/${entry.value.asset}'; hash='${entry.value.sha256}' ;;",
    };
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
trap 'rm -rf -- "\$tmp"' EXIT
case "\$(uname -m)" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) exit 7 ;; esac
asset="sky-ui-linux-\$arch.tar.gz"
base='https://github.com/skyonave/sky_ui/releases/download/v$version'
curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 --max-filesize 4096 -o "\$tmp/panel.sha256" "\$base/\$asset.sha256"
expected=\$(awk -v name="\$asset" '\$2 == name || \$2 == "*"name {print \$1}' "\$tmp/panel.sha256")
[[ "\$expected" =~ ^[a-fA-F0-9]{64}\$ ]]
curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 --max-filesize 150000000 -o "\$tmp/panel.tar.gz" "\$base/\$asset"
printf '%s  %s\\n' "\$expected" "\$tmp/panel.tar.gz" | sha256sum -c - >/dev/null
mkdir "\$tmp/bundle"
tar -xzf "\$tmp/panel.tar.gz" -C "\$tmp/bundle" ./bin/sky-ops ./lib ./VERSION ./LICENSE ./licenses ./deploy/host_packages.sh
[[ "\$(cat "\$tmp/bundle/VERSION")" == '$version' ]]
curl -fsSL --proto '=https' --tlsv1.2 --max-time 90 --max-filesize 100000000 -o "\$tmp/core.gz" "\$url"
printf '%s  %s\\n' "\$hash" "\$tmp/core.gz" | sha256sum -c - >/dev/null
gzip -dc -- "\$tmp/core.gz" > "\$tmp/mihomo"
chmod 0700 "\$tmp/mihomo"
printf '%s\\n' '$publicKey' > "\$tmp/panel.pub"
cat > "\$tmp/installer" <<'SKY_UI_NODE_INSTALLER'
${await script.readAsString()}
SKY_UI_NODE_INSTALLER
if (( EUID == 0 )); then
  /bin/bash "\$tmp/installer" "\$tmp/mihomo" "\$tmp/panel.pub" "\$tmp/bundle"
else
  sudo -n /bin/bash "\$tmp/installer" "\$tmp/mihomo" "\$tmp/panel.pub" "\$tmp/bundle"
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
    Future<void>? cancellation,
  }) async {
    final path = _path(id);
    // An automatic bounded inventory must not make an explicit action fail busy.
    final inventory = _inventories[id];
    if (operation != 'v3:inventory' && inventory != null) {
      try {
        await inventory;
      } on Object {
        /* The explicit operation retries the host. */
      }
    }
    if (!_busy.add(id)) throw const ApiException('server_busy', status: 409);
    final changesState =
        operation == '/bin/bash -s' ||
        {
          'start',
          'stop',
          'restart',
          'deploy',
          'rollback',
        }.contains(operation) ||
        RegExp(
          r'^v3:(start|stop|restart|deploy|rollback|install|update|remove):',
        ).hasMatch(operation);
    if (changesState) _readiness.invalidate(id);
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
      final result =
          (input != null || cancellation != null) &&
              transport is NativeCommandRunner
          ? await transport.runWithInput(
              '/usr/bin/ssh',
              arguments,
              input: input ?? '',
              cancellation: cancellation,
              timeout: operation == '/bin/bash -s'
                  ? const Duration(minutes: 5)
                  : operation.startsWith('v3:validate:') ||
                        operation.startsWith('v3:deploy:')
                  ? const Duration(seconds: 90)
                  : const Duration(seconds: 65),
            )
          : await transport.run(
              '/usr/bin/ssh',
              arguments,
              timeout:
                  operation.startsWith('v3:install:') ||
                      operation.startsWith('v3:update:')
                  ? const Duration(minutes: 10)
                  : operation == 'v3:inventory'
                  ? const Duration(seconds: 8)
                  : const Duration(seconds: 40),
            );
      if (result.exitCode != 0) {
        final reported = RegExp(
          r'(?:^|\n)Sky UI: ([a-z_]+)(?:\r?\n|$)',
        ).firstMatch(result.output)?.group(1);
        const safeErrors = {
          'binary_missing',
          'core_release_unverified',
          'catalog_unavailable',
          'release_checksum_failed',
          'core_build_space_required',
          'core_build_failed',
          'core_dependencies_missing',
          'listener_not_ready',
          'route_configuration_out_of_sync',
          'transaction_aborted',
          'route_geo_unknown',
          'route_geo_unavailable',
          'route_policy_invalid',
        };
        throw ApiException(
          reported != null && safeErrors.contains(reported)
              ? reported
              : operation.startsWith('v3:') && result.exitCode == 2
              ? 'server_upgrade_required'
              : operation == '/bin/bash -s' && result.exitCode == 7
              ? 'server_bootstrap_arch'
              : result.exitCode == 255
              ? 'server_ssh_failed'
              : 'server_operation_failed',
          status: 502,
        );
      }
      return result.output.trim();
    } finally {
      if (changesState) _readiness.invalidate(id);
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
      _readiness.invalidate(id);
      _busy.remove(id);
    }
  }
}
