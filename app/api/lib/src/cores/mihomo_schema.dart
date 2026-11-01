import 'dart:convert';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'mihomo_native.g.dart';

/// UI policy over the pinned inventory; the browser treats field IDs as opaque.
class MihomoSchemas {
  MihomoSchemas({
    this.certificateIds = const [],
    this.certificateHosts = const {},
    this.publicAddress = '',
    this.networkAdministration = false,
  });
  final List<String> certificateIds;
  final Map<String, String> certificateHosts;
  final String publicAddress;
  final bool networkAdministration;
  static const systemProtocols = {
    'redirect',
    'tproxy',
    'tun',
    'tunnel',
    'hysteria2-realm',
  };
  static const isolatedProtocols = {'shadowsocks', 'snell', 'sudoku'};
  static const names = {
    'vless': 'VLESS',
    'vmess': 'VMess',
    'trojan': 'Trojan',
    'shadowsocks': 'Shadowsocks',
    'snell': 'Snell',
    'mieru': 'Mieru',
    'sudoku': 'Sudoku',
    'trusttunnel': 'TrustTunnel',
    'tuic': 'TUIC',
    'tuic-v4': 'TUIC v4',
    'hysteria2': 'Hysteria 2',
    'hysteria2-realm': 'Hysteria 2 Realm',
    'shadowquic': 'ShadowQUIC',
    'anytls': 'AnyTLS',
    'http': 'HTTP',
    'socks': 'SOCKS',
    'mixed': 'Mixed',
    'redirect': 'Redirect',
    'tproxy': 'TProxy',
    'tun': 'TUN',
    'tunnel': 'Tunnel',
  };
  List<String> transports(String id) => switch (id) {
    'vless' => ['TCP', 'WebSocket', 'gRPC', 'XHTTP'],
    'vmess' => ['TCP', 'WebSocket', 'gRPC'],
    'trojan' => ['TCP', 'WebSocket', 'gRPC'],
    'mieru' => ['TCP', 'UDP'],
    'shadowsocks' => ['TCP'],
    'tuic' || 'tuic-v4' || 'hysteria2' || 'shadowquic' => ['QUIC'],
    'trusttunnel' => ['TCP', 'QUIC', 'TCP + QUIC'],
    'tun' => ['IP'],
    'tunnel' => ['TCP', 'UDP', 'TCP + UDP'],
    _ => ['TCP'],
  };
  List<String> securities(String id) => switch (id) {
    'vless' => ['REALITY', 'TLS'],
    'vmess' || 'trojan' || 'anytls' => ['TLS'],
    'shadowsocks' || 'snell' => ['Built-in'],
    'mieru' || 'sudoku' => ['Built-in'],
    'tuic' || 'tuic-v4' || 'hysteria2' || 'trusttunnel' => ['TLS'],
    'shadowquic' => ['JLS'],
    'http' || 'socks' || 'mixed' => ['None', 'TLS'],
    'hysteria2-realm' => ['TLS'],
    _ => ['None'],
  };
  List<ProtocolDefinition> get protocols => [
    for (final id in names.keys) definition(id),
  ];
  List<Map<String, dynamic>> nativeFields(String id) =>
      mihomoNativeInventory[id == 'tuic-v4' ? 'tuic' : id]!;
  ProtocolDefinition definition(String id) {
    final transport = transports(id), security = securities(id);
    final fields = <ProtocolField>[
      ProtocolField(
        'transport',
        kind: 'choice',
        group: 'transport',
        options: transport,
        defaultValue: transport.first,
        required: true,
      ),
      ProtocolField(
        'security',
        kind: 'choice',
        group: 'security',
        options: security,
        optionWhen: const {
          'REALITY': {
            'transport': ['TCP'],
          },
        },
        defaultValue: security.first,
        required: true,
      ),
      ProtocolField(
        'listen',
        advanced: true,
        defaultValue: systemProtocols.contains(id) ? '127.0.0.1' : '::',
        required: true,
      ),
      if (security.contains('TLS')) ...[
        ProtocolField(
          'certificateSource',
          group: 'security',
          options: const ['panel', 'custom'],
          kind: 'choice',
          optionWhen: const {
            'panel': {
              '_managedCertificatesReady': ['true'],
            },
          },
          defaultValue: certificateIds.isEmpty ? 'custom' : 'panel',
          when: const {
            'security': ['TLS'],
          },
        ),
        ProtocolField(
          'certificateId',
          group: 'security',
          options: certificateIds,
          defaultValue: certificateIds.contains('panel')
              ? 'panel'
              : certificateIds.firstOrNull ?? '',
          when: const {
            'security': ['TLS'],
            'certificateSource': ['panel'],
          },
          required: true,
        ),
        ProtocolField(
          'tlsCertificate',
          required: true,
          group: 'security',
          kind: 'multiline',
          secret: true,
          maxLength: 65536,
          when: const {
            'security': ['TLS'],
            'certificateSource': ['custom'],
          },
        ),
        ProtocolField(
          'tlsPrivateKey',
          required: true,
          group: 'security',
          kind: 'multiline',
          secret: true,
          maxLength: 65536,
          when: const {
            'security': ['TLS'],
            'certificateSource': ['custom'],
          },
        ),
      ],
      if (id != 'shadowquic' &&
          security.any((v) => ['TLS', 'REALITY', 'JLS'].contains(v))) ...[
        ProtocolField(
          'serverName',
          derivedFrom: 'certificateId',
          deriveWhen: const {
            'security': ['TLS'],
            'certificateSource': ['panel'],
          },
          deriveValueMap: certificateHosts,
          group: 'security',
          defaultValue: security.first == 'REALITY'
              ? 'www.microsoft.com'
              : publicAddress,
          helpKey: security.first == 'REALITY'
              ? 'help.realityServerName'
              : 'help.serverName',
          when: {
            'security': security
                .where((v) => v != 'None' && v != 'Built-in')
                .toList(),
          },
        ),
        ProtocolField(
          'handshakePort',
          group: 'security',
          kind: 'integer',
          minimum: 1,
          maximum: 65535,
          defaultValue: '443',
          when: const {
            'security': ['REALITY'],
          },
        ),
      ],
      if (id == 'vless')
        ProtocolField(
          'flow',
          group: 'security',
          defaultValue: 'xtls-rprx-vision',
          options: const ['None', 'xtls-rprx-vision'],
          when: const {
            'transport': ['TCP'],
            'security': ['TLS', 'REALITY'],
          },
        ),
      if (id == 'vmess')
        const ProtocolField(
          'clientCipher',
          options: ['auto', 'aes-128-gcm', 'chacha20-poly1305', 'zero', 'none'],
          defaultValue: 'auto',
          advanced: true,
        ),
      if (security.any((s) => s != 'None' && s != 'Built-in')) ...[
        ProtocolField(
          'clientAlpn',
          group: 'security',
          kind: 'lines',
          advanced: true,
          when: {
            'security': security
                .where((s) => s != 'None' && s != 'Built-in')
                .toList(),
          },
        ),
        if ({
          'vless',
          'vmess',
          'trojan',
          'anytls',
          'shadowsocks',
          'snell',
        }.contains(id))
          ProtocolField(
            'clientFingerprint',
            group: 'security',
            advanced: true,
            defaultValue: 'chrome',
            options: const [
              'chrome',
              'firefox',
              'safari',
              'ios',
              'android',
              'edge',
              '360',
              'qq',
              'random',
              'randomized',
            ],
            when: {
              'security': security
                  .where((s) => s != 'None' && s != 'Built-in')
                  .toList(),
            },
          ),
      ],
      if (id == 'vmess')
        const ProtocolField(
          'alterId',
          kind: 'integer',
          minimum: 0,
          maximum: 65535,
          defaultValue: '0',
          advanced: true,
        ),
      if (id == 'hysteria2-realm')
        const ProtocolField(
          'realmToken',
          secret: true,
          required: true,
          maxLength: 512,
        ),
    ];
    for (final native in nativeFields(id)) {
      final path = List<String>.from(native['path'] as List),
          full = path.join('.');
      final when = <String, List<String>>{}, group = _group(path);
      if (full == 'ws-path') when['transport'] = ['WebSocket'];
      if (full == 'grpc-service-name') when['transport'] = ['gRPC'];
      if (path.first == 'xhttp-config') when['transport'] = ['XHTTP'];
      if (id == 'hysteria2' && full == 'obfs-password')
        when['native.obfs'] = ['salamander'];
      fields.add(
        _field(
          native,
          group: group,
          when: when,
          defaultValue: _default(id, full),
          advanced: !const {
            'ws-path',
            'grpc-service-name',
            'cipher',
            'version',
            'target',
            'stack',
            'device',
            'transport',
            'jls-upstream.addr',
            'jls-upstream.sni',
            'xhttp-config.path',
            'xhttp-config.mode',
            'obfs',
          }.contains(full),
        ),
      );
    }
    return ProtocolDefinition(
      id,
      names[id]!,
      fields,
      usesPort: id != 'tun',
      category: systemProtocols.contains(id) ? 'system' : 'proxy',
      shareable: !systemProtocols.contains(id),
      clientFieldBindings: const {
        'transport': 'transport',
        'security': 'security',
      },
      deliveryHintKey:
          {
            'snell',
            'mieru',
            'sudoku',
            'trusttunnel',
            'shadowquic',
            'tuic-v4',
          }.contains(id)
          ? 'builder.profileOnly'
          : null,
      isolatedBindings: isolatedProtocols.contains(id),
      available:
          !{'tun', 'tproxy', 'redirect'}.contains(id) || networkAdministration,
      unavailableKey:
          !networkAdministration && {'tun', 'tproxy', 'redirect'}.contains(id)
          ? 'builder.networkRightsRequired'
          : null,
      context: {
        '_netAdmin': '$networkAdministration',
        '_managedCertificatesReady': '${certificateIds.isNotEmpty}',
      },
    );
  }

  String _group(List<String> path) => switch (path.first) {
    'ws-path' || 'grpc-service-name' || 'xhttp-config' => 'transport',
    'jls-upstream' || 'alpn' => 'security',
    _ => 'parameters',
  };

  ProtocolField _field(
    Map<String, dynamic> native, {
    required String group,
    required Map<String, List<String>> when,
    String defaultValue = '',
    bool advanced = true,
    bool rowChild = false,
  }) {
    final path = (native['path'] as List).join('.'),
        type = native['type'] as String;
    final name = path;
    var options = _options(name);
    var kind = type == 'bool'
        ? 'boolean'
        : type == 'rows' || type == 'map'
        ? 'rows'
        : type.startsWith('[]')
        ? 'lines'
        : type.startsWith('int') || type.startsWith('uint')
        ? 'integer'
        : 'text';
    if (name.endsWith('padding-scheme') ||
        name.endsWith('ech-key') ||
        name.endsWith('client-auth-cert'))
      kind = 'multiline';
    if (type == 'bool' && native['nullable'] == true) {
      options = ['auto', 'true', 'false'];
      kind = 'text';
      if (defaultValue.isEmpty) defaultValue = 'auto';
    } else if (type == 'bool' && defaultValue.isEmpty)
      defaultValue = 'false';
    if (options.isNotEmpty && defaultValue.isEmpty && !options.contains(''))
      options = ['', ...options];
    return ProtocolField(
      'native.$name',
      kind: kind,
      itemKind: type == '[]int' || type.startsWith('[]uint')
          ? 'integer'
          : 'text',
      rowKeyField: type == 'map' ? 'native.key' : null,
      required: (rowChild && native['required'] == true) || name == 'target',
      group: group,
      advanced: advanced,
      when: when,
      options: options,
      defaultValue: defaultValue,
      minimum: type.startsWith('uint') || type.startsWith('[]uint') ? 0 : null,
      maxLength: 65536,
      secret:
          (!rowChild || !{'key', 'value'}.contains(name)) &&
              RegExp(
                r'(^|\.)(password|token|key|seed|ech-key|private-key)$',
              ).hasMatch(name) ||
          name.endsWith('obfs-password'),
      labelKey: 'mihomo.native.$name',
      helpKey: 'mihomo.native.$name.help',
      children: [
        for (final child in native['children'] as List? ?? [])
          _field(
            Map<String, dynamic>.from(child as Map),
            group: group,
            when: const {},
            advanced: false,
            rowChild: true,
          ),
      ],
    );
  }

  List<String> _options(String path) => switch (path) {
    'cipher' => [
      'chacha20-ietf-poly1305',
      'aes-128-gcm',
      'aes-256-gcm',
      '2022-blake3-aes-128-gcm',
      '2022-blake3-aes-256-gcm',
      '2022-blake3-chacha20-poly1305',
    ],
    'version' => ['1', '2', '3', '4', '5'],
    'stack' => ['gvisor', 'system', 'mixed'],
    'xhttp-config.mode' => ['auto', 'stream-one', 'stream-up', 'packet-up'],
    'congestion-controller' => ['bbr', 'cubic', 'new_reno'],
    'obfs' => ['', 'salamander'],
    'http-mask-mode' => ['legacy', 'stream', 'poll', 'auto'],
    'aead-method' => ['chacha20-poly1305', 'aes-128-gcm', 'none'],
    _ => [],
  };
  String _default(String id, String path) {
    final common = <String, String>{
      'cipher': 'chacha20-ietf-poly1305',
      'version': '4',
      'stack': 'gvisor',
      'xhttp-config.path': '/connect',
      'xhttp-config.mode': 'auto',
      'ws-path': '/connect',
      'grpc-service-name': 'tunnel',
      'jls-upstream.addr': 'www.google.com:443',
      'jls-upstream.sni': 'www.google.com',
      'dns-hijack': '0.0.0.0:53',
      'mtu': '1500',
    };
    if (path == 'udp') return 'true';
    if (id == 'mieru' && path == 'user-hint-is-mandatory') return 'true';
    if (const {'tuic', 'tuic-v4', 'shadowquic'}.contains(id)) {
      if (path == 'alpn') return 'h3';
      if (path == 'congestion-controller') return 'bbr';
      if (path == 'zero-rtt') return 'true';
      if (path == 'max-idle-time')
        return id == 'shadowquic' ? '30000' : '15000';
      if (path == 'authentication-timeout') return '1000';
      if (path == 'max-udp-relay-packet-size') return '1500';
      if (path == 'max-datagram-frame-size')
        return id == 'shadowquic' ? '1400' : '0';
    }
    return common[path] ?? '';
  }

  Map<String, Object?> convert(String id, Map<String, String> settings) {
    final out = <String, Object?>{};
    for (final entry in nativeFields(id)) {
      final path = List<String>.from(entry['path'] as List),
          key = 'native.${path.join('.')}';
      final value = settings[key];
      if (value == null ||
          value.isEmpty ||
          (entry['nullable'] == true && value == 'auto'))
        continue;
      _put(out, path, _value(entry, value));
    }
    return out;
  }

  Object _value(Map<String, dynamic> descriptor, String value) {
    final type = descriptor['type'] as String;
    if (type == 'bool') return value == 'true';
    if (type.startsWith('int') || type.startsWith('uint'))
      return int.parse(value);
    if (type.startsWith('[]'))
      return value
          .split('\n')
          .map((v) => v.trim())
          .where((v) => v.isNotEmpty)
          .map(
            (v) =>
                type == '[]int' || type.startsWith('[]uint') ? int.parse(v) : v,
          )
          .toList();
    if (type == 'map' || type == 'rows') {
      final rows = jsonDecode(value) as List;
      Map<String, Object?> row(Map raw) {
        final result = <String, Object?>{};
        for (final child in descriptor['children'] as List) {
          final field = Map<String, dynamic>.from(child as Map),
              path = List<String>.from(field['path'] as List);
          if (type == 'map' && path.first == 'key') continue;
          final text = raw['native.${path.join('.')}'] ?? raw[path.join('.')];
          if (text is String &&
              text.isNotEmpty &&
              !(field['nullable'] == true && text == 'auto'))
            _put(result, path, _value(field, text));
        }
        return result;
      }

      if (type == 'rows') return rows.map((v) => row(v as Map)).toList();
      return {
        for (final raw in rows)
          (raw['native.key'] ?? raw['key']) as String:
              ((descriptor['children'] as List).length == 2 &&
                  (descriptor['children'] as List)[1]['path'].first == 'value')
              ? row(raw as Map)['value']
              : row(raw as Map),
      };
    }
    return value;
  }
}

void _put(Map<String, Object?> out, List<String> path, Object value) {
  if (path.length == 1) {
    out[path.first] = value;
    return;
  }
  final node =
      (out[path.first] ??= <String, Object?>{}) as Map<String, Object?>;
  _put(node, path.sublist(1), value);
}
