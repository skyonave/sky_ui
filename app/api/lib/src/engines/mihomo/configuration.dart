import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:yaml/yaml.dart';

import '../../application/access/records.dart';
import '../../application/access/validation.dart';
import '../../application/contracts/configuration_codec.dart';
import '../../application/contracts/connection_diagnostics.dart';
import '../diagnostic_target.dart';
import '../../infrastructure/network/socket_owner.dart';
import '../../infrastructure/process/command_runner.dart';
import '../../shared/api_exception.dart';
import '../contracts.dart';
import '../managed_core.dart';
import 'schema.dart';
import 'settings.dart';

class MihomoConfiguration
    implements
        ConfigurationCodec,
        CoreSettingsCodec,
        ConnectionDiagnosticsCodec {
  @override
  ConnectionDiagnosticPlan diagnosticPlan(
    PanelData data,
    StoredConnection connection,
  ) {
    // Diagnose the stored binding even when its certificate has since expired.
    // Saving/compiling still uses strict schema validation in _settings.
    final settings = connection.value.settings;
    return diagnosticTargets(
      listeners: [
        for (final s in _sockets(data, validate: false))
          DiagnosticListener(host: s.host, port: s.port, udp: s.udp),
      ],
      settings: settings,
      realityTarget: _destination(settings),
    );
  }

  @override
  List<ProtocolField> get coreSettingsFields => MihomoSettings.fields;
  @override
  Map<String, String> readCoreSettings(
    String native,
    Map<String, String>? stored,
  ) => MihomoSettings.read(native, stored);
  @override
  Map<String, String> prepareCoreSettings(
    String native,
    Map<String, String>? stored,
    Map<String, String> input,
  ) => MihomoSettings.prepare(native, stored, input);
  MihomoConfiguration({
    this.supervisor,
    this.core,
    this.runner = const NativeCommandRunner(),
    this.certificatesDirectory,
    this.publicAddress = '',
    this.networkAdministration = false,
  });
  final ProcessSupervisor? supervisor;
  final ManagedCore? core;
  final CommandRunner runner;
  final String? certificatesDirectory;
  final String publicAddress;
  final bool networkAdministration;
  @override
  String get coreId => 'mihomo';
  Map<String, dynamic> get certificates {
    try {
      final file = File('$certificatesDirectory/index.json');
      if (!file.existsSync()) return {};
      final index = Map<String, dynamic>.from(
        jsonDecode(file.readAsStringSync()) as Map,
      );
      return {
        for (final entry in index.entries)
          if (entry.value is Map &&
              entry.value['host'] is String &&
              DateTime.tryParse(
                    entry.value['expiresAt'] as String? ?? '',
                  )?.isAfter(
                    DateTime.now().toUtc().add(const Duration(minutes: 1)),
                  ) ==
                  true)
            entry.key: entry.value,
      };
    } on Object {
      return {};
    }
  }

  MihomoSchemas get schema => MihomoSchemas(
    certificateIds: certificates.keys.toList(),
    certificateHosts: {
      for (final e in certificates.entries)
        if (e.value is Map && e.value['host'] is String)
          e.key: e.value['host'] as String,
    },
    publicAddress: publicAddress,
    networkAdministration: networkAdministration,
  );
  @override
  List<ProtocolDefinition> get protocols => schema.protocols;
  ProtocolDefinition _definition(String id) =>
      schema.protocols.where((p) => p.id == id).firstOrNull ??
      (throw const ApiException('protocol_unavailable', status: 422));
  @override
  Map<String, String> validateSettings(Connection connection) {
    final definition = _definition(connection.protocolId);
    if (!definition.available)
      throw ApiException(
        'protocol_unavailable',
        status: 422,
        fields: {'protocol': definition.unavailableKey ?? 'choice_invalid'},
      );
    final allowed = definition.fields.map((f) => f.id).toSet();
    if (connection.settings.keys.any((key) => !allowed.contains(key)))
      throw const ApiException('settings_unsupported', status: 422);
    final values = definition.defaults(connection.settings);
    final errors = definition.validateFields({...values});
    // Explicit incompatible input must be rejected, not repaired as if it had been applied.
    for (final f in definition.fields) {
      if (connection.settings.containsKey(f.id) &&
          (connection.settings[f.id] ?? '').isNotEmpty) {
        if (!f.visible(values))
          errors[f.id] = 'choice_invalid';
        else if (f.options.isNotEmpty &&
            !f.allowedOptions(values).contains(connection.settings[f.id]))
          errors[f.id] = 'choice_invalid';
      }
    }
    if (InternetAddress.tryParse(values['listen'] ?? '') == null)
      errors['listen'] = 'format_invalid';
    if (!{'None', 'Built-in'}.contains(values['security'])) {
      final name = values['serverName'] ?? '';
      if (name.isEmpty &&
          values['security'] == 'TLS' &&
          values['certificateSource'] == 'panel')
        values['serverName'] = values['certificateId'] ?? '';
      if ((values['serverName'] ?? '').isNotEmpty &&
          !validAddress(values['serverName']!))
        errors['serverName'] = 'format_invalid';
      if (values['security'] == 'REALITY' &&
          ((values['serverName'] ?? '').isEmpty ||
              InternetAddress.tryParse(values['serverName']!) != null))
        errors['serverName'] = 'format_invalid';
    }
    if (values['security'] == 'TLS' && values['certificateSource'] == 'panel') {
      if (!certificates.containsKey(values['certificateId']))
        errors['certificateId'] = 'choice_invalid';
      values['serverName'] =
          schema.certificateHosts[values['certificateId']] ?? '';
    }
    if (connection.protocolId == 'tun' &&
        (values['native.device'] ?? '').isNotEmpty &&
        (!RegExp(
              r'^[A-Za-z0-9_.-]{1,15}$',
            ).hasMatch(values['native.device']!) ||
            {'.', '..'}.contains(values['native.device'])))
      errors['native.device'] = 'format_invalid';
    void tlsPair(String certificate, String privateKey) {
      if ((values[certificate] ?? '').isEmpty ||
          (values[privateKey] ?? '').isEmpty)
        return;
      try {
        final context = SecurityContext(withTrustedRoots: false);
        context.useCertificateChainBytes(utf8.encode(values[certificate]!));
        context.usePrivateKeyBytes(utf8.encode(values[privateKey]!));
      } on Object {
        errors[certificate] = 'certificate_invalid';
        errors[privateKey] = 'certificate_invalid';
      }
    }

    if (values['security'] == 'TLS' && values['certificateSource'] == 'custom')
      tlsPair('tlsCertificate', 'tlsPrivateKey');
    if ((values['clientCertificate'] ?? '').isNotEmpty ||
        (values['clientPrivateKey'] ?? '').isNotEmpty) {
      for (final id in ['clientCertificate', 'clientPrivateKey'])
        if ((values[id] ?? '').isEmpty) errors[id] = 'required';
      tlsPair('clientCertificate', 'clientPrivateKey');
    }
    if (errors.isNotEmpty)
      throw ApiException('settings_unsupported', status: 422, fields: errors);
    return {
      for (final f in definition.activeFields(values))
        f.id: values[f.id] ?? f.initialValue(values),
    };
  }

  Map<String, String> _settings(StoredConnection connection) {
    final definition = _definition(connection.value.protocolId),
        values = Map<String, String>.from(connection.value.settings),
        visibility = definition.defaults(connection.value.settings);
    for (final f in definition.activeFields(visibility)) {
      if (f.secret && connection.secrets.containsKey('field:${f.id}'))
        values[f.id] = connection.secrets['field:${f.id}']!;
    }
    return validateSettings(
      Connection(
        id: connection.value.id,
        name: connection.value.name,
        coreId: connection.value.coreId,
        protocolId: connection.value.protocolId,
        port: connection.value.port,
        enabled: connection.value.enabled,
        settings: values,
      ),
    );
  }

  String _random([int bytes = 32]) =>
      base64.encode(List.generate(bytes, (_) => Random.secure().nextInt(256)));
  Future<Map<String, String>> _generate(String command) async {
    if (core == null) throw const ApiException('binary_missing', status: 409);
    final result = await runner.run(core!.binary, ['generate', command]);
    if (result.exitCode != 0)
      throw const ApiException('credential_generation_failed');
    return {
      for (final match in RegExp(
        r'^(PrivateKey|PublicKey|Seed|Client|Password): ([^\r\n]+)',
        multiLine: true,
      ).allMatches(result.output))
        match[1]!: match[2]!,
    };
  }

  @override
  Future<Map<String, String>> connectionSecrets(
    Connection connection, {
    Map<String, String> previous = const {},
  }) async {
    final out = Map<String, String>.of(previous);
    if (connection.protocolId == 'vless' &&
        connection.settings['security'] == 'REALITY' &&
        out['privateKey'] == null) {
      final key = await (await X25519().newKeyPair()).extract();
      out.addAll({
        'privateKey': base64Url.encode(key.bytes).replaceAll('=', ''),
        'publicKey': base64Url.encode(key.publicKey.bytes).replaceAll('=', ''),
        'shortId': List.generate(
          8,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
      });
    }
    out.putIfAbsent('validationPassword', () => _random());
    if (connection.protocolId == 'sudoku' && out['sudokuServerKey'] == null) {
      final generated = await _generate('sudoku-keypair');
      out['sudokuServerKey'] =
          generated['PublicKey'] ??
          (throw const ApiException('credential_generation_failed'));
      out['sudokuClientKey'] =
          generated['PrivateKey'] ??
          (throw const ApiException('credential_generation_failed'));
    }
    for (final f in _definition(
      connection.protocolId,
    ).activeFields(connection.settings)) {
      if (f.secret && (connection.settings[f.id] ?? '').isNotEmpty)
        out['field:${f.id}'] = connection.settings[f.id]!;
    }
    for (final id in [
      if ({'salamander', 'gecko'}.contains(connection.settings['native.obfs']))
        'native.obfs-password',
    ]) {
      if ((out['field:$id'] ?? '').isEmpty) out['field:$id'] = secureToken();
    }
    if (connection.settings['security'] == 'TLS' &&
        connection.settings['certificateSource'] == 'custom') {
      final errors = {
        for (final id in ['tlsCertificate', 'tlsPrivateKey'])
          if ((out['field:$id'] ?? '').isEmpty) id: 'required',
      };
      if (errors.isNotEmpty)
        throw ApiException('settings_unsupported', status: 422, fields: errors);
    }
    return out;
  }

  @override
  Future<Map<String, String>> grantCredentials(
    StoredConnection connection, {
    Map<String, String> previous = const {},
  }) async {
    final out = <String, String>{...previous};
    out.putIfAbsent('uuid', newUuid);
    out.putIfAbsent('username', () => secureToken(12));
    out.putIfAbsent('password', () => secureToken());
    if (connection.value.protocolId == 'shadowsocks') {
      final cipher =
          connection.value.settings['native.cipher'] ??
          'chacha20-ietf-poly1305';
      if (cipher.startsWith('2022-')) {
        final size = cipher == '2022-blake3-aes-128-gcm' ? 16 : 32;
        try {
          if (base64.decode(out['password']!).length != size)
            out['password'] = _random(size);
        } on Object {
          out['password'] = _random(size);
        }
      }
    }
    if (connection.value.protocolId == 'sudoku' &&
        out['sudokuServerKey'] == null) {
      final generated = await _generate('sudoku-keypair');
      out['sudokuServerKey'] = generated['PublicKey']!;
      out['sudokuClientKey'] = generated['PrivateKey']!;
    }
    return out;
  }

  @override
  ClientEndpoint clientEndpoint(
    StoredConnection connection,
    AccessGrant grant,
    String address,
  ) {
    final c = connection.value,
        s = _settings(connection),
        native = schema.convert(c.protocolId, s);
    final credentials = <String, String>{
      for (final key in ['uuid', 'username', 'password'])
        if (grant.credentials[key] != null) key: grant.credentials[key]!,
      if (grant.credentials['sudokuClientKey'] != null)
        'sudokuKey': grant.credentials['sudokuClientKey']!,
      'shadowQuicUsername': grant.id,
      if (s['security'] == 'REALITY')
        'publicKey': connection.secrets['publicKey']!,
      if (s['security'] == 'REALITY') 'shortId': connection.secrets['shortId']!,
    };
    final settings = <String, String>{
      for (final key in [
        'transport',
        'security',
        'serverName',
        'flow',
        'alterId',
        'clientCipher',
        'clientFingerprint',
      ])
        if (s[key] != null) key: s[key]!,
      if (native['cipher'] != null)
        'cipher': native['cipher'] == 'dummy'
            ? 'none'
            : native['cipher'] as String,
      if (native['version'] != null) 'version': '${native['version']}',
      if (native['udp'] != null) 'udp': '${native['udp']}',
      if (native['ws-path'] != null)
        'websocketPath': native['ws-path'] as String,
      if (native['grpc-service-name'] != null)
        'grpcServiceName': native['grpc-service-name'] as String,
      if (s['clientAlpn']?.isNotEmpty == true) 'clientAlpn': s['clientAlpn']!,
    };
    void object(String key, Object? value) {
      if (value is Map && value.isNotEmpty) settings[key] = jsonEncode(value);
    }

    object(
      'xhttpOptions',
      _select(native['xhttp-config'], const ['path', 'host', 'mode']),
    );
    final options = <String, Object?>{};
    void copy(List<String> keys) {
      options.addAll(_select(native, keys));
    }

    switch (c.protocolId) {
      case 'hysteria2':
        copy([
          'obfs',
          'obfs-password',
          'obfs-min-packet-size',
          'obfs-max-packet-size',
          'alpn',
          'up',
          'down',
          'cwnd',
          'bbr-profile',
          'udp-mtu',
          'initial-stream-receive-window',
          'max-stream-receive-window',
          'initial-connection-receive-window',
          'max-connection-receive-window',
        ]);
      case 'tuic' || 'tuic-v4':
        copy([
          'congestion-controller',
          'alpn',
          'max-udp-relay-packet-size',
          'max-datagram-frame-size',
          'cwnd',
          'bbr-profile',
        ]);
      case 'shadowquic':
        copy([
          'alpn',
          'quic-versions',
          'zero-rtt',
          'congestion-controller',
          'up',
          'down',
          'cwnd',
          'bbr-profile',
          'recv-window-conn',
          'recv-window',
          'disable-mtu-discovery',
          'max-datagram-frame-size',
        ]);
        settings['serverName'] =
            s['native.jls-upstream.sni'] ?? 'www.google.com';
      case 'trusttunnel':
        copy(['congestion-controller', 'cwnd', 'bbr-profile']);
      case 'mieru':
        copy(['traffic-pattern']);
      case 'sudoku':
        copy([
          'aead-method',
          'padding-min',
          'padding-max',
          'table-type',
          'enable-pure-downlink',
          'http-mask-mode',
          'path-root',
          'custom-table',
          'custom-tables',
          'httpmask',
        ]);
        options['http-mask'] = native['disable-http-mask'] != true;
    }
    object('protocolOptions', options);
    if (s['security'] == 'TLS' && s['certificateSource'] == 'custom') {
      final match = RegExp(
        r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----',
      ).firstMatch(s['tlsCertificate'] ?? '');
      if (match != null) {
        try {
          credentials['fingerprint'] = sha256
              .convert(base64.decode(match[1]!.replaceAll(RegExp(r'\s'), '')))
              .toString();
        } on Object {}
      }
    }
    return ClientEndpoint(
      id: c.id,
      name: c.name,
      server: address,
      port: int.parse(grant.credentials['port'] ?? '${c.port}'),
      protocolId: c.protocolId,
      settings: settings,
      credentials: credentials,
    );
  }

  List<({StoredConnection connection, List<AccessGrant> grants, int port})>
  _listeners(PanelData data, {bool validationOnly = false}) {
    final result =
        <({StoredConnection connection, List<AccessGrant> grants, int port})>[];
    for (final c in data.connections) {
      if (!validationOnly && !c.value.enabled) continue;
      final definition = _definition(c.value.protocolId);
      var grants = data.activeGrants(c.value.id);
      if (!validationOnly && definition.shareable && grants.isEmpty) continue;
      if (validationOnly && grants.isEmpty)
        grants = [
          AccessGrant(
            id: 'validation',
            recipientId: 'validation',
            connectionId: c.value.id,
            credentials: {
              'uuid': '00000000-0000-4000-8000-000000000001',
              'username': 'validation',
              'password':
                  c.value.protocolId == 'shadowsocks' &&
                      c.value.settings['native.cipher'] ==
                          '2022-blake3-aes-128-gcm'
                  ? base64.encode(List.filled(16, 1))
                  : c.secrets['validationPassword'] ??
                        base64.encode(List.filled(32, 1)),
              if (c.secrets['sudokuServerKey'] != null)
                'sudokuServerKey': c.secrets['sudokuServerKey']!,
            },
          ),
        ];
      if (definition.isolatedBindings) {
        for (final g in grants)
          result.add((
            connection: c,
            grants: [g],
            port: int.parse(g.credentials['port'] ?? '${c.value.port}'),
          ));
      } else
        result.add((connection: c, grants: grants, port: c.value.port ?? 0));
    }
    return result;
  }

  List<({String host, int port, bool udp})> _sockets(
    PanelData data, {
    bool validate = true,
  }) {
    final result = <({String host, int port, bool udp})>[];
    for (final listener in _listeners(data)) {
      final c = listener.connection,
          s = validate ? _settings(c) : c.value.settings,
          id = c.value.protocolId,
          transport = s['transport'],
          host = s['listen'] ?? '::';
      if (id == 'tun') continue;
      final udpOnly =
          {'tuic', 'tuic-v4', 'hysteria2', 'shadowquic'}.contains(id) ||
          id == 'mieru' && transport == 'UDP';
      final both =
          {'shadowsocks', 'socks', 'mixed', 'tproxy'}.contains(id) &&
              s['native.udp'] != 'false' ||
          transport == 'TCP + UDP' ||
          transport == 'TCP + QUIC';
      if (!udpOnly && transport != 'QUIC' && transport != 'UDP')
        result.add((host: host, port: listener.port, udp: false));
      if (udpOnly || both || transport == 'QUIC' || transport == 'UDP')
        result.add((host: host, port: listener.port, udp: true));
    }
    return result;
  }

  String _tunDevice(StoredConnection c) =>
      c.value.settings['native.device']?.isNotEmpty == true
      ? c.value.settings['native.device']!
      : 'sky${sha256.convert(utf8.encode(c.value.id)).toString().substring(0, 10)}';
  List<String> _tunDevices(PanelData data) => data.connections
      .where((c) => c.value.enabled && c.value.protocolId == 'tun')
      .map(_tunDevice)
      .toList();

  @override
  Future<void> preflight(
    PanelData before,
    PanelData after,
    bool running,
  ) async {
    final devices = _tunDevices(after),
        previous = running ? _tunDevices(before).toSet() : <String>{};
    if (devices.toSet().length != devices.length)
      throw const ApiException('interface_in_use', status: 422);
    if (Platform.isLinux) {
      for (final name in devices)
        if (!previous.contains(name) &&
            await Directory('/sys/class/net/$name').exists())
          throw const ApiException('interface_in_use', status: 422);
    }
    final owned = running
        ? _sockets(before).map((s) => '${s.port}:${s.udp}').toSet()
        : <String>{};
    for (final binding in _sockets(after)) {
      if (owned.contains('${binding.port}:${binding.udp}') ||
          binding.port < 1024)
        continue;
      try {
        if (binding.udp) {
          final socket = await RawDatagramSocket.bind(
            binding.host,
            binding.port,
            reuseAddress: false,
            reusePort: false,
          );
          socket.close();
        } else {
          final socket = await ServerSocket.bind(
            binding.host,
            binding.port,
            shared: false,
          );
          await socket.close();
        }
      } on SocketException {
        throw const ApiException('port_unavailable', status: 422);
      }
    }
  }

  @override
  Future<void> verifyRunning(PanelData data, ManagedCore core) async {
    final bindings = _sockets(data);
    final devices = _tunDevices(data);
    if (bindings.isEmpty && devices.isEmpty) return;
    final pid = (await supervisor?.inspect(core))?.processId;
    if (pid == null || pid <= 0)
      throw const ApiException('listener_identity_unavailable');
    final uid = await processUid(pid);
    for (final name in devices) {
      var ready = false;
      for (var attempt = 0; attempt < 10; attempt++) {
        ready =
            Platform.isLinux &&
            await File('/sys/class/net/$name/tun_flags').exists();
        if (ready) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!ready) throw const ApiException('listener_not_ready');
    }
    for (final binding in bindings) {
      var ready = false;
      for (var attempt = 0; attempt < 10; attempt++) {
        ready = await boundSocketBelongsTo(
          binding.host,
          binding.port,
          uid,
          udp: binding.udp,
        );
        if (ready) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!ready) throw const ApiException('listener_not_ready', status: 503);
    }
  }

  @override
  String compile(
    PanelData data,
    ManagedCore core,
    String previous, {
    bool validationOnly = false,
  }) {
    final loaded = loadYaml(previous);
    if (loaded is! Map)
      throw const ApiException('configuration_invalid', status: 422);
    final base = Map<String, Object?>.from(_plain(loaded) as Map),
        existing = base['listeners'];
    if (existing != null && existing is! List)
      throw const ApiException('configuration_invalid', status: 422);
    final owned = <Map<String, Object?>>[];
    for (final listener in _listeners(data, validationOnly: validationOnly)) {
      final stored = listener.connection,
          c = stored.value,
          s = _settings(stored),
          grants = listener.grants;
      if (c.coreId != coreId || c.instanceId != core.id)
        throw const ApiException('core_unavailable', status: 422);
      final out = <String, Object?>{
        'name':
            'sky-ui/${c.id}${_definition(c.protocolId).isolatedBindings ? '/${grants.first.id}' : ''}',
        'type': c.protocolId == 'tuic-v4'
            ? 'tuic'
            : c.protocolId == 'redirect'
            ? 'redir'
            : c.protocolId,
        'listen': s['listen'],
        if (c.port != null) 'port': listener.port,
        'proxy': s['routingProxy'] ?? 'DIRECT',
        if (s['routingRule']?.isNotEmpty == true) 'rule': s['routingRule'],
        if (s['routingMark']?.isNotEmpty == true)
          'routing-mark': int.parse(s['routingMark']!),
        ...schema.convert(c.protocolId, s),
      };
      if (c.protocolId == 'tun') out['device'] = _tunDevice(stored);
      switch (c.protocolId) {
        case 'vless' || 'vmess':
          out['users'] = [
            for (final g in grants)
              {
                'username': g.id,
                'uuid': g.credentials['uuid'],
                if (c.protocolId == 'vmess')
                  'alterId': int.tryParse(s['alterId'] ?? '0') ?? 0,
                if (c.protocolId == 'vless' &&
                    s['flow'] != null &&
                    s['flow'] != 'None')
                  'flow': s['flow'],
              },
          ];
        case 'trojan':
          out['users'] = [
            for (final g in grants)
              {'username': g.id, 'password': g.credentials['password']},
          ];
        case 'anytls' || 'hysteria2':
          out['users'] = {
            for (final g in grants) g.id: g.credentials['password'],
          };
        case 'mieru':
          out['users'] = {
            for (final g in grants)
              g.credentials['username']: g.credentials['password'],
          };
          out['transport'] = s['transport'];
        case 'trusttunnel' || 'http' || 'socks' || 'mixed':
          out['users'] = [
            for (final g in grants)
              {
                'username': g.credentials['username'],
                'password': g.credentials['password'],
              },
          ];
        case 'shadowquic':
          out['users'] = [
            for (final g in grants)
              {'username': g.id, 'password': g.credentials['password']},
          ];
        case 'tuic':
          out['users'] = {
            for (final g in grants)
              g.credentials['uuid']: g.credentials['password'],
          };
        case 'tuic-v4':
          out['token'] = [for (final g in grants) g.credentials['password']];
        case 'shadowsocks':
          out['password'] = grants.first.credentials['password'];
        case 'snell':
          out['psk'] = grants.first.credentials['password'];
        case 'sudoku':
          out['key'] =
              grants.first.credentials['sudokuServerKey'] ??
              stored.secrets['sudokuServerKey'];
        case 'hysteria2-realm':
          out['token'] = s['realmToken'];
      }
      if (c.protocolId == 'tunnel' || c.protocolId == 'trusttunnel')
        out['network'] = [
          if (s['transport'] != 'UDP' && s['transport'] != 'QUIC') 'tcp',
          if (s['transport'] != 'TCP') 'udp',
        ];
      _protection(out, stored, s, grants);
      owned.add(out);
    }
    MihomoSettings.apply(base, owned, data.coreSettings[core.id]);
    base['listeners'] = [
      if (existing is List)
        ...existing.where(
          (v) =>
              v is! Map ||
              !(v['name']?.toString().startsWith('sky-ui/') ?? false),
        ),
      ...owned,
    ];
    return '${const JsonEncoder.withIndent('  ').convert(base)}\n';
  }

  String _destination(Map<String, String> s) =>
      '${s['serverName']}:${s['handshakePort'] ?? '443'}';
  void _protection(
    Map<String, Object?> out,
    StoredConnection stored,
    Map<String, String> s,
    List<AccessGrant> grants,
  ) {
    if (stored.value.protocolId == 'shadowquic') return;
    final protection = s['security'];
    if (protection == 'TLS') {
      if (s['certificateSource'] == 'custom') {
        out['certificate'] = s['tlsCertificate'];
        out['private-key'] = s['tlsPrivateKey'];
      } else {
        final id = s['certificateId']!;
        if (!certificates.containsKey(id) ||
            !RegExp(r'^[A-Za-z0-9][A-Za-z0-9.-]*$').hasMatch(id))
          throw const ApiException('certificate_unavailable', status: 422);
        out['certificate'] = '$certificatesDirectory/$id/fullchain.pem';
        out['private-key'] = '$certificatesDirectory/$id/private.key';
      }
    } else if (protection == 'REALITY') {
      _assign(out, ['reality-config', 'dest'], _destination(s));
      _assign(out, [
        'reality-config',
        'private-key',
      ], stored.secrets['privateKey']!);
      _assign(out, ['reality-config', 'short-id'], [stored.secrets['shortId']]);
      final existing = (out['reality-config'] as Map)['server-names'];
      if (existing is! List || existing.isEmpty)
        _assign(out, ['reality-config', 'server-names'], [s['serverName']]);
    }
  }
}

void _assign(Map<String, Object?> target, List<String> path, Object value) {
  if (path.length == 1) {
    target[path.first] = value;
    return;
  }
  final node =
      (target[path.first] ??= <String, Object?>{}) as Map<String, Object?>;
  _assign(node, path.sublist(1), value);
}

Object? _plain(Object? value) {
  if (value is Map)
    return value.map((k, v) => MapEntry(k.toString(), _plain(v)));
  if (value is List) return value.map(_plain).toList();
  return value;
}

Map<String, Object?> _select(Object? node, List<String> keys) => node is Map
    ? {
        for (final key in keys)
          if (node[key] != null) key: node[key],
      }
    : {};
