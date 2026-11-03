import 'package:sky_ui_shared/sky_ui_shared.dart';

ProtocolDefinition proxyProtocolDefinition(
  String coreId,
  String id,
  Map<String, dynamic> certificates,
) {
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
