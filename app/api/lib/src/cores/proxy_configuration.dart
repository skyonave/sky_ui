import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import '../config.dart';
import '../errors.dart';
import '../panel/configuration_codec.dart';
import '../panel/domain.dart';
import '../panel/validation.dart';
import 'contracts.dart';
import 'socket_owner.dart';

/// Shared protocol semantics for JSON proxy engines; native documents stay distinct.
class ProxyConfiguration implements ConfigurationCodec {
  ProxyConfiguration(
    this.coreId, {
    required this.supervisor,
    required this.core,
    this.certificatesDirectory = '/var/lib/sky-ui-certificates',
  });
  @override
  final String coreId;
  final ProcessSupervisor supervisor;
  final ManagedCore core;
  final String certificatesDirectory;
  Map<String, dynamic> get certificates {
    try {
      final values =
          jsonDecode(
                File('$certificatesDirectory/index.json').readAsStringSync(),
              )
              as Map;
      return {
        for (final e in values.entries)
          if (e.value is Map &&
              DateTime.tryParse(e.value['expiresAt'] as String? ?? '')?.isAfter(
                    DateTime.now().toUtc().add(const Duration(minutes: 1)),
                  ) ==
                  true)
            e.key as String: e.value,
      };
    } on Object {
      return {};
    }
  }

  @override
  List<ProtocolDefinition> get protocols => [
    for (final id
        in coreId == 'xray'
            ? ['vless', 'shadowsocks']
            : ['vless', 'shadowsocks', 'hysteria2', 'tuic', 'naive'])
      _definition(id),
  ];
  ProtocolDefinition _definition(String id) {
    final vless = id == 'vless', ss = id == 'shadowsocks';
    final transports = vless
        ? ['TCP', 'WebSocket', 'gRPC', if (coreId == 'xray') 'XHTTP']
        : ss
        ? ['TCP']
        : id == 'naive'
        ? ['HTTP/2', 'HTTP/3']
        : ['QUIC'];
    final tls = {
      'security': ['TLS'],
    };
    return ProtocolDefinition(
      id,
      productProtocol(id)!.name,
      [
        ProtocolField(
          'transport',
          group: 'transport',
          kind: 'choice',
          options: transports,
          defaultValue: transports.first,
        ),
        ProtocolField(
          'security',
          group: 'security',
          kind: 'choice',
          options: vless
              ? ['REALITY', 'TLS']
              : ss
              ? ['Built-in']
              : ['TLS'],
          defaultValue: vless
              ? 'REALITY'
              : ss
              ? 'Built-in'
              : 'TLS',
          optionWhen: {
            'REALITY': {
              'transport': ['TCP', if (coreId == 'xray') 'XHTTP'],
            },
          },
        ),
        const ProtocolField(
          'listen',
          defaultValue: '::',
          required: true,
          advanced: true,
        ),
        if (coreId == 'sing-box' &&
            {'shadowsocks', 'hysteria2', 'tuic'}.contains(id))
          const ProtocolField(
            'udpTimeout',
            kind: 'integer',
            advanced: true,
            defaultValue: '300',
            minimum: 10,
            maximum: 3600,
          ),
        if (id == 'naive')
          const ProtocolField(
            'naiveCongestionControl',
            options: ['bbr', 'cubic', 'reno'],
            defaultValue: 'bbr',
            advanced: true,
            when: {
              'transport': ['HTTP/3'],
            },
          ),
        if (!ss) ...[
          ProtocolField(
            'tlsMaxVersion',
            group: 'security',
            advanced: true,
            options: id == 'hysteria2' || id == 'tuic'
                ? const ['1.3']
                : const ['1.2', '1.3'],
            defaultValue: '1.3',
            when: tls,
          ),
          ProtocolField(
            'tlsMinVersion',
            group: 'security',
            options: id == 'hysteria2' || id == 'tuic'
                ? const ['1.3']
                : const ['1.2', '1.3'],
            defaultValue: id == 'hysteria2' || id == 'tuic' ? '1.3' : '1.2',
            when: tls,
            optionWhen: const {
              '1.2': {
                'transport': ['TCP', 'WebSocket', 'gRPC', 'XHTTP', 'HTTP/2'],
              },
            },
          ),
          ProtocolField(
            'serverName',
            required: true,
            defaultValue: 'www.kernel.org',
            derivedFrom: 'certificateId',
            deriveWhen: const {
              'security': ['TLS'],
              'certificateSource': ['panel'],
            },
            deriveValueMap: {
              for (final e in certificates.entries)
                e.key: e.value['host'] as String,
            },
          ),
          ProtocolField(
            'certificateSource',
            kind: 'choice',
            options: const ['panel', 'custom'],
            defaultValue: 'panel',
            when: tls,
          ),
          ProtocolField(
            'certificateId',
            options: certificates.keys.toList(),
            defaultValue: certificates.keys.firstOrNull ?? '',
            required: true,
            when: const {
              'security': ['TLS'],
              'certificateSource': ['panel'],
            },
          ),
          const ProtocolField(
            'tlsCertificate',
            kind: 'multiline',
            required: true,
            maxLength: 32768,
            when: {
              'security': ['TLS'],
              'certificateSource': ['custom'],
            },
          ),
          const ProtocolField(
            'tlsPrivateKey',
            kind: 'multiline',
            secret: true,
            required: true,
            maxLength: 32768,
            when: {
              'security': ['TLS'],
              'certificateSource': ['custom'],
            },
          ),
        ],
        if (vless) ...[
          const ProtocolField(
            'clientAlpn',
            kind: 'lines',
            group: 'security',
            advanced: true,
            maxLength: 64,
            when: {
              'security': ['TLS'],
            },
          ),
          const ProtocolField(
            'realityMaxTimeDiff',
            kind: 'integer',
            group: 'security',
            advanced: true,
            defaultValue: '0',
            minimum: 0,
            maximum: 3600,
            when: {
              'security': ['REALITY'],
            },
          ),
          const ProtocolField(
            'realityTarget',
            defaultValue: 'www.kernel.org:443',
            required: true,
            when: {
              'security': ['REALITY'],
            },
          ),
          const ProtocolField(
            'flow',
            kind: 'choice',
            options: ['xtls-rprx-vision', 'None'],
            defaultValue: 'xtls-rprx-vision',
            when: {
              'transport': ['TCP'],
            },
          ),
          const ProtocolField(
            'clientFingerprint',
            defaultValue: 'chrome',
            advanced: true,
            options: [
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
          ),
          const ProtocolField(
            'websocketHost',
            advanced: true,
            group: 'transport',
            maxLength: 253,
            when: {
              'transport': ['WebSocket'],
            },
          ),
          const ProtocolField(
            'websocketPath',
            generator: 'path',
            defaultValue: '/tunnel',
            required: true,
            when: {
              'transport': ['WebSocket'],
            },
          ),
          const ProtocolField(
            'grpcServiceName',
            generator: 'service',
            defaultValue: 'tunnel',
            required: true,
            when: {
              'transport': ['gRPC'],
            },
          ),
          if (coreId == 'xray') ...[
            const ProtocolField(
              'xhttpPath',
              generator: 'path',
              defaultValue: '/tunnel',
              required: true,
              when: {
                'transport': ['XHTTP'],
              },
            ),
            const ProtocolField(
              'xhttpMode',
              kind: 'choice',
              options: ['auto', 'packet-up', 'stream-up', 'stream-one'],
              defaultValue: 'auto',
              when: {
                'transport': ['XHTTP'],
              },
            ),
            const ProtocolField(
              'xhttpHost',
              when: {
                'transport': ['XHTTP'],
              },
              maxLength: 253,
            ),
          ],
        ],
        if (ss)
          const ProtocolField(
            'cipher',
            kind: 'choice',
            options: ['chacha20-ietf-poly1305', 'aes-128-gcm', 'aes-256-gcm'],
            defaultValue: 'chacha20-ietf-poly1305',
          ),
        if (id == 'hysteria2') ...[
          const ProtocolField(
            'hysteriaMasquerade',
            advanced: true,
            maxLength: 2048,
          ),
          const ProtocolField(
            'obfs',
            kind: 'choice',
            group: 'security',
            options: ['', 'salamander'],
            defaultValue: '',
          ),
          const ProtocolField(
            'obfsPassword',
            generator: 'token',
            secret: true,
            when: {
              'obfs': ['salamander'],
            },
          ),
          const ProtocolField(
            'upMbps',
            kind: 'integer',
            defaultValue: '100',
            minimum: 1,
            maximum: 100000,
          ),
          const ProtocolField(
            'downMbps',
            kind: 'integer',
            defaultValue: '100',
            minimum: 1,
            maximum: 100000,
          ),
        ],
        if (id == 'tuic') ...[
          const ProtocolField(
            'tuicAuthTimeout',
            kind: 'integer',
            advanced: true,
            defaultValue: '3',
            minimum: 1,
            maximum: 30,
          ),
          const ProtocolField(
            'tuicHeartbeat',
            kind: 'integer',
            advanced: true,
            defaultValue: '10',
            minimum: 1,
            maximum: 120,
          ),
          const ProtocolField(
            'congestionController',
            kind: 'choice',
            options: ['bbr', 'cubic', 'new_reno'],
            defaultValue: 'bbr',
          ),
        ],
      ],
      isolatedBindings: ss,
      clientFieldBindings: const {
        'transport': 'transport',
        'security': 'security',
      },
    );
  }

  @override
  Map<String, String> validateSettings(Connection connection) {
    final d = protocols.where((d) => d.id == connection.protocolId).firstOrNull;
    if (d == null)
      throw const ApiException('protocol_unavailable', status: 422);
    if (connection.settings.keys.any((id) => !d.fields.any((f) => f.id == id)))
      throw const ApiException('settings_unsupported', status: 422);
    final values = d.defaults(connection.settings);
    for (final entry in connection.settings.entries) {
      final field = d.fields.firstWhere((f) => f.id == entry.key);
      if (field.options.isNotEmpty &&
          !field.allowedOptions(values).contains(entry.value)) {
        throw ApiException(
          'settings_unsupported',
          status: 422,
          fields: {entry.key: 'choice_invalid'},
        );
      }
    }
    if (values['security'] == 'TLS' && values['certificateSource'] == 'panel') {
      values['serverName'] =
          certificates[values['certificateId']]?['host'] as String? ??
          values['serverName'] ??
          '';
    }
    final errors = d.validateFields(values);
    if (values['hysteriaMasquerade']?.isNotEmpty == true) {
      final url = Uri.tryParse(values['hysteriaMasquerade']!);
      if (url == null ||
          url.scheme != 'https' ||
          !validAddress(url.host) ||
          url.userInfo.isNotEmpty ||
          url.hasFragment)
        errors['hysteriaMasquerade'] = 'format_invalid';
    }
    if (values['security'] == 'TLS' &&
        double.parse(values['tlsMinVersion']!) >
            double.parse(values['tlsMaxVersion']!)) {
      errors['tlsMaxVersion'] = 'range_invalid';
    }
    final alpn = (values['clientAlpn'] ?? '')
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final allowedAlpn = switch (values['transport']) {
      'WebSocket' => {'http/1.1'},
      'gRPC' => {'h2'},
      _ => {'h2', 'http/1.1'},
    };
    if (alpn.any((value) => !allowedAlpn.contains(value)))
      errors['clientAlpn'] = 'choice_invalid';
    if (values.containsKey('clientAlpn'))
      values['clientAlpn'] = alpn.toSet().join('\n');
    if (values['websocketHost']?.isNotEmpty == true) {
      final host = Uri.tryParse('http://${values['websocketHost']}');
      if (host == null ||
          !validAddress(host.host) ||
          host.userInfo.isNotEmpty ||
          host.path.isNotEmpty ||
          host.hasQuery ||
          host.hasFragment ||
          host.hasPort && (host.port < 1 || host.port > 65535))
        errors['websocketHost'] = 'format_invalid';
    }
    if (InternetAddress.tryParse(values['listen'] ?? '') == null)
      errors['listen'] = 'format_invalid';
    if (values['serverName']?.isNotEmpty == true &&
        !validAddress(values['serverName']!))
      errors['serverName'] = 'format_invalid';
    if (values['security'] == 'REALITY') {
      final target = values['realityTarget'] ?? '';
      final parsed = Uri.tryParse('tcp://$target');
      if (parsed == null ||
          !validAddress(parsed.host) ||
          parsed.userInfo.isNotEmpty ||
          parsed.path.isNotEmpty ||
          parsed.hasQuery ||
          parsed.hasFragment ||
          !parsed.hasPort ||
          parsed.port < 1 ||
          parsed.port > 65535)
        errors['realityTarget'] = 'format_invalid';
    }
    if (values['security'] == 'TLS') {
      if (values['certificateSource'] == 'panel' &&
          !certificates.containsKey(values['certificateId']))
        errors['certificateId'] = 'choice_invalid';
      if (values['certificateSource'] == 'custom') {
        try {
          SecurityContext(withTrustedRoots: false)
            ..useCertificateChainBytes(
              utf8.encode(values['tlsCertificate'] ?? ''),
            )
            ..usePrivateKeyBytes(utf8.encode(values['tlsPrivateKey'] ?? ''));
        } on Object {
          errors['tlsCertificate'] = 'certificate_invalid';
        }
      }
    }
    for (final id in ['websocketPath', 'xhttpPath']) {
      if (values[id]?.isNotEmpty == true &&
          (!values[id]!.startsWith('/') ||
              values[id]!.contains(RegExp(r'[\r\n]'))))
        errors[id] = 'format_invalid';
    }
    if (errors.isNotEmpty)
      throw ApiException('settings_unsupported', status: 422, fields: errors);
    return {
      for (final f in d.activeFields(values))
        f.id: values[f.id] ?? f.initialValue(values),
    };
  }

  Map<String, String> _settings(StoredConnection connection) => {
    ...connection.value.settings,
    for (final f in _definition(
      connection.value.protocolId,
    ).fields.where((f) => f.secret))
      if (connection.secrets['field:${f.id}'] != null)
        f.id: connection.secrets['field:${f.id}']!,
  };
  @override
  Future<Map<String, String>> connectionSecrets(
    Connection connection, {
    Map<String, String> previous = const {},
  }) async {
    final values = {...previous};
    if (connection.protocolId == 'hysteria2' &&
        connection.settings['obfs'] == 'salamander' &&
        (values['field:obfsPassword'] ?? '').isEmpty) {
      values['field:obfsPassword'] =
          connection.settings['obfsPassword']?.isNotEmpty == true
          ? connection.settings['obfsPassword']!
          : secureToken();
    }
    if (connection.settings['security'] == 'REALITY' &&
        values['privateKey'] == null) {
      final key = await (await X25519().newKeyPair()).extract();
      values.addAll({
        'privateKey': base64Url.encode(key.bytes).replaceAll('=', ''),
        'publicKey': base64Url.encode(key.publicKey.bytes).replaceAll('=', ''),
        'shortId': List.generate(
          8,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
      });
    }
    return values;
  }

  @override
  Future<Map<String, String>> grantCredentials(
    StoredConnection connection, {
    Map<String, String> previous = const {},
  }) async => {
    ...previous,
    'uuid': previous['uuid'] ?? newUuid(),
    'username': previous['username'] ?? secureToken(12),
    'password': previous['password'] ?? secureToken(),
  };

  Map<String, Object?> _tls(StoredConnection connection, {required bool xray}) {
    final s = _settings(connection), reality = s['security'] == 'REALITY';
    if (reality) {
      final target = Uri.parse('https://${s['realityTarget']}');
      return xray
          ? {
              'show': false,
              'target': s['realityTarget'],
              'serverNames': [s['serverName']],
              'privateKey': connection.secrets['privateKey'],
              'shortIds': [connection.secrets['shortId']],
              // Current mihomo advertises this REALITY wire version even in
              // recent builds; Xray's implicit minimum otherwise rejects it.
              'minClientVer': '1.8.2',
              if ((int.tryParse(s['realityMaxTimeDiff'] ?? '') ?? 0) > 0)
                'maxTimeDiff': int.parse(s['realityMaxTimeDiff']!) * 1000,
            }
          : {
              'enabled': true,
              'server_name': s['serverName'],
              'reality': {
                'enabled': true,
                'handshake': {
                  'server': target.host,
                  'server_port': target.port,
                },
                'private_key': connection.secrets['privateKey'],
                'short_id': [connection.secrets['shortId']],
                if ((int.tryParse(s['realityMaxTimeDiff'] ?? '') ?? 0) > 0)
                  'max_time_difference': '${s['realityMaxTimeDiff']}s',
              },
            };
    }
    final panel = s['certificateSource'] == 'panel';
    final cert = panel ? certificates[s['certificateId']] as Map? : null;
    if (panel && cert == null)
      throw const ApiException('certificate_unavailable', status: 422);
    if (xray)
      return {
        'serverName': s['serverName'],
        'minVersion': s['tlsMinVersion'] ?? '1.2',
        'maxVersion': s['tlsMaxVersion'] ?? '1.3',
        if ((s['clientAlpn'] ?? '').isNotEmpty)
          'alpn': s['clientAlpn']!.split('\n'),
        'certificates': [
          {
            if (panel) ...{
              'certificateFile':
                  '$certificatesDirectory/${s['certificateId']}/fullchain.pem',
              'keyFile':
                  '$certificatesDirectory/${s['certificateId']}/private.key',
            } else ...{
              'certificate': (s['tlsCertificate'] ?? '').trim().split('\n'),
              'key': (s['tlsPrivateKey'] ?? '').trim().split('\n'),
            },
          },
        ],
      };
    return {
      'enabled': true,
      'server_name': s['serverName'],
      'min_version': s['tlsMinVersion'] ?? '1.2',
      'max_version': s['tlsMaxVersion'] ?? '1.3',
      if ((s['clientAlpn'] ?? '').isNotEmpty)
        'alpn': s['clientAlpn']!.split('\n'),
      if (connection.value.protocolId == 'tuic') 'alpn': ['h3'],
      if (panel) ...{
        'certificate_path':
            '$certificatesDirectory/${s['certificateId']}/fullchain.pem',
        'key_path': '$certificatesDirectory/${s['certificateId']}/private.key',
      } else ...{
        'certificate': (s['tlsCertificate'] ?? '').trim().split('\n'),
        'key': (s['tlsPrivateKey'] ?? '').trim().split('\n'),
      },
    };
  }

  Map<String, Object?> _inbound(
    StoredConnection c,
    List<AccessGrant> grants,
    int port,
    String tag,
  ) {
    final id = c.value.protocolId, s = _settings(c), xray = coreId == 'xray';
    final users = [
      for (final g in grants)
        switch (id) {
          'vless' =>
            xray
                ? {
                    'id': g.credentials['uuid'],
                    'email': g.id,
                    'flow': s['transport'] == 'TCP' && s['flow'] != 'None'
                        ? s['flow'] ?? 'xtls-rprx-vision'
                        : '',
                  }
                : {
                    'name': g.id,
                    'uuid': g.credentials['uuid'],
                    'flow': s['transport'] == 'TCP' && s['flow'] != 'None'
                        ? s['flow'] ?? 'xtls-rprx-vision'
                        : '',
                  },
          'tuic' => {
            'name': g.id,
            'uuid': g.credentials['uuid'],
            'password': g.credentials['password'],
          },
          'naive' => {
            'username': g.credentials['username'],
            'password': g.credentials['password'],
          },
          _ => {'name': g.id, 'password': g.credentials['password']},
        },
    ];
    if (xray)
      return {
        'tag': tag,
        'listen': s['listen'] ?? '::',
        'port': port,
        'protocol': id,
        'settings': id == 'vless'
            ? {'decryption': 'none', 'clients': users}
            : {
                'method': s['cipher'],
                'password': grants.single.credentials['password'],
                'network': 'tcp,udp',
              },
        if (id == 'vless')
          'streamSettings': {
            'network': switch (s['transport']) {
              'WebSocket' => 'ws',
              'gRPC' => 'grpc',
              'XHTTP' => 'xhttp',
              _ => 'raw',
            },
            'security': s['security'] == 'REALITY' ? 'reality' : 'tls',
            if (s['security'] == 'REALITY')
              'realitySettings': _tls(c, xray: true)
            else
              'tlsSettings': _tls(c, xray: true),
            if (s['transport'] == 'WebSocket')
              'wsSettings': {
                'path': s['websocketPath'],
                if ((s['websocketHost'] ?? '').isNotEmpty)
                  'host': s['websocketHost'],
              },
            if (s['transport'] == 'gRPC')
              'grpcSettings': {'serviceName': s['grpcServiceName']},
            if (s['transport'] == 'XHTTP')
              'xhttpSettings': {
                'path': s['xhttpPath'],
                'mode': s['xhttpMode'],
                if (s['xhttpHost']?.isNotEmpty == true) 'host': s['xhttpHost'],
              },
          },
      };
    return {
      'type': id,
      'tag': tag,
      'listen': s['listen'] ?? '::',
      'listen_port': port,
      if ((s['udpTimeout'] ?? '').isNotEmpty)
        'udp_timeout': '${s['udpTimeout']}s',
      if (id == 'shadowsocks') ...{
        'method': s['cipher'],
        'password': grants.single.credentials['password'],
      } else
        'users': users,
      if (id != 'shadowsocks') 'tls': _tls(c, xray: false),
      if (id == 'vless' && s['transport'] != 'TCP')
        'transport': {
          'type': s['transport'] == 'WebSocket' ? 'ws' : 'grpc',
          if (s['transport'] == 'WebSocket')
            'path': s['websocketPath']
          else
            'service_name': s['grpcServiceName'],
        },
      if (id == 'naive') 'network': s['transport'] == 'HTTP/3' ? 'udp' : 'tcp',
      if (id == 'naive' && s['transport'] == 'HTTP/3')
        'quic_congestion_control': s['naiveCongestionControl'] ?? 'bbr',
      if (id == 'hysteria2') ...{
        if ((s['hysteriaMasquerade'] ?? '').isNotEmpty)
          'masquerade': s['hysteriaMasquerade'],
        'up_mbps': int.parse(s['upMbps'] ?? '100'),
        'down_mbps': int.parse(s['downMbps'] ?? '100'),
        if (s['obfs']?.isNotEmpty == true)
          'obfs': {'type': s['obfs'], 'password': s['obfsPassword']},
      },
      if (id == 'tuic') ...{
        'congestion_control': s['congestionController'] ?? 'bbr',
        'auth_timeout': '${s['tuicAuthTimeout'] ?? '3'}s',
        'heartbeat': '${s['tuicHeartbeat'] ?? '10'}s',
      },
    };
  }

  List<
    ({
      StoredConnection connection,
      List<AccessGrant> grants,
      int port,
      String tag,
    })
  >
  _listeners(PanelData data, bool validationOnly) {
    return [
      for (final c in data.connections.where((c) => c.value.enabled))
        if (data.activeGrants(c.value.id).isNotEmpty || validationOnly)
          for (final grants
              in _definition(c.value.protocolId).isolatedBindings
                  ? [
                      for (final g in data.activeGrants(c.value.id)) [g],
                      if (validationOnly &&
                          data.activeGrants(c.value.id).isEmpty)
                        [_validationGrant(c)],
                    ]
                  : [
                      data.activeGrants(c.value.id).isEmpty
                          ? [_validationGrant(c)]
                          : data.activeGrants(c.value.id),
                    ])
            (
              connection: c,
              grants: grants,
              port:
                  int.tryParse(grants.first.credentials['port'] ?? '') ??
                  c.value.port!,
              tag:
                  'sky-${c.value.id}${_definition(c.value.protocolId).isolatedBindings ? '-${grants.first.id}' : ''}',
            ),
    ];
  }

  AccessGrant _validationGrant(StoredConnection c) => AccessGrant(
    id: 'validation',
    recipientId: '',
    connectionId: c.value.id,
    credentials: {
      'uuid': 'fdd8be42-a0f8-4370-a01b-5735ca178849',
      'username': 'validation',
      'password': 'validation-configuration-only',
    },
  );
  @override
  String compile(
    PanelData data,
    ManagedCore core,
    String previous, {
    bool validationOnly = false,
  }) {
    final inbounds = [
      for (final l in _listeners(data, validationOnly))
        _inbound(l.connection, l.grants, l.port, l.tag),
    ];
    return '${const JsonEncoder.withIndent('  ').convert(coreId == 'xray' ? {
            'log': {'loglevel': 'warning'},
            'inbounds': inbounds,
            'outbounds': [
              {'protocol': 'freedom', 'tag': 'direct'},
            ],
          } : {
            'log': {'level': 'info', 'timestamp': true},
            'inbounds': inbounds,
            'outbounds': [
              {'type': 'direct', 'tag': 'direct'},
            ],
          })}\n';
  }

  @override
  Future<void> preflight(
    PanelData before,
    PanelData after,
    bool running,
  ) async {
    final previous = running
        ? _listeners(before, false).map((l) => l.port).toSet()
        : <int>{};
    for (final l in _listeners(after, false)) {
      if (previous.contains(l.port)) continue;
      ServerSocket? tcp;
      RawDatagramSocket? udp;
      try {
        final quic =
            {'tuic', 'hysteria2'}.contains(l.connection.value.protocolId) ||
            _settings(l.connection)['transport'] == 'HTTP/3';
        if (!quic)
          tcp = await ServerSocket.bind(
            _settings(l.connection)['listen'] ?? '::',
            l.port,
            shared: false,
          );
        if (quic || l.connection.value.protocolId == 'shadowsocks')
          udp = await RawDatagramSocket.bind(
            _settings(l.connection)['listen'] ?? '::',
            l.port,
            reuseAddress: false,
            reusePort: false,
          );
      } on SocketException {
        throw const ApiException('port_in_use', status: 422);
      } finally {
        await tcp?.close();
        udp?.close();
      }
    }
  }

  @override
  Future<void> verifyRunning(PanelData data, ManagedCore core) async {
    final process = await supervisor.inspect(core);
    if (!Platform.isLinux) return;
    if (process.processId == null || process.processId! <= 0)
      throw const ApiException('listener_not_ready');
    final uid = await processUid(process.processId!);
    for (final l in _listeners(data, false)) {
      final quic =
          {'tuic', 'hysteria2'}.contains(l.connection.value.protocolId) ||
          _settings(l.connection)['transport'] == 'HTTP/3';
      var ready = false;
      for (var attempt = 0; attempt < 15; attempt++) {
        if (await boundSocketBelongsTo(
              _settings(l.connection)['listen'] ?? '::',
              l.port,
              uid,
              udp: quic,
            ) &&
            (l.connection.value.protocolId != 'shadowsocks' ||
                await boundSocketBelongsTo(
                  _settings(l.connection)['listen'] ?? '::',
                  l.port,
                  uid,
                  udp: true,
                ))) {
          ready = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!ready) throw const ApiException('listener_not_ready');
    }
  }

  @override
  ClientEndpoint clientEndpoint(
    StoredConnection connection,
    AccessGrant grant,
    String address,
  ) {
    final s = _settings(connection);
    return ClientEndpoint(
      id: grant.id,
      name: connection.value.name,
      server: address,
      port:
          int.tryParse(grant.credentials['port'] ?? '') ??
          connection.value.port!,
      protocolId: connection.value.protocolId,
      settings: {
        for (final key in [
          'transport',
          'security',
          'serverName',
          'flow',
          'clientFingerprint',
          'clientAlpn',
          'websocketPath',
          'websocketHost',
          'grpcServiceName',
          'cipher',
          'congestionController',
          'obfs',
          'obfsPassword',
        ])
          if (s[key] != null) key: s[key]!,
        if (s['transport'] == 'XHTTP')
          'xhttpOptions': jsonEncode({
            'path': s['xhttpPath'],
            'mode': s['xhttpMode'],
            if (s['xhttpHost']?.isNotEmpty == true) 'host': s['xhttpHost'],
          }),
        if (coreId == 'xray' && s['security'] == 'REALITY')
          'realityMlkem': 'true',
        if (connection.value.protocolId == 'hysteria2')
          'protocolOptions': jsonEncode({
            if (s['obfs']?.isNotEmpty == true) ...{
              'obfs': s['obfs'],
              'obfs-password': s['obfsPassword'],
            },
            'up': '${s['upMbps']} Mbps',
            'down': '${s['downMbps']} Mbps',
          }),
        if (connection.value.protocolId == 'tuic')
          'protocolOptions': jsonEncode({
            'congestion-controller': s['congestionController'],
          }),
      },
      credentials: {
        for (final key in ['uuid', 'username', 'password'])
          if (grant.credentials[key] != null) key: grant.credentials[key]!,
        if (s['security'] == 'REALITY') ...{
          'publicKey': connection.secrets['publicKey']!,
          'shortId': connection.secrets['shortId']!,
        },
      },
    );
  }
}
