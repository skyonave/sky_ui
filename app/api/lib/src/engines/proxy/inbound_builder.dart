import '../../application/access/records.dart';
import '../../shared/api_exception.dart';

/// Native JSON listeners. It receives resolved settings and does not own access state.
class ProxyInboundBuilder {
  ProxyInboundBuilder({
    required this.coreId,
    required this.certificatesDirectory,
    required this.certificates,
    required this.readSettings,
  });
  final String coreId, certificatesDirectory;
  final Map<String, dynamic> certificates;
  final Map<String, String> Function(StoredConnection) readSettings;
  Map<String, Object?> _tls(StoredConnection connection, {required bool xray}) {
    final s = readSettings(connection), reality = s['security'] == 'REALITY';
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

  Map<String, Object?> build(
    StoredConnection c,
    List<AccessGrant> grants,
    int port,
    String tag,
  ) {
    final id = c.value.protocolId, s = readSettings(c), xray = coreId == 'xray';
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
}
