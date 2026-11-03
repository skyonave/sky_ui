import 'dart:convert';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import '../errors.dart';
import 'domain.dart';

// Client identity selects the response format, never access permissions.
final _uriSubscriptionClients = RegExp(
  r'(?:^|[\s;(])(?:v2box|v2rayng?|v2raytun|happ|streisand|shadowrocket|hiddify(?:next)?|nekobox|nekoray|karing|throne)[\w.-]*(?:[/\s;()]|$)',
  caseSensitive: false,
);
final _clashSubscriptionClients = RegExp(
  r'(?:^|[\s;(])(?:clash[\w.-]*|mihomo[\w.-]*|flclash[\w.-]*|stash)(?:[/\s;()]|$)',
  caseSensitive: false,
);

String subscriptionFormatFor(String userAgent) {
  if (_uriSubscriptionClients.hasMatch(userAgent)) return 'v2ray';
  return _clashSubscriptionClients.hasMatch(userAgent) ? 'clash' : 'v2ray';
}

abstract interface class ClientExporter {
  String get format;
  List<ClientExportRestriction> get restrictions;
  bool canExport(List<ClientEndpoint> endpoints);
  String profile(List<ClientEndpoint> endpoints);
  List<ShareLink> links(List<ClientEndpoint> endpoints);
}

String? subscriptionClientFor(String userAgent) =>
    RegExp(
      r'(?:^|[\s;(])v2box(?:[/\s;()]|$)',
      caseSensitive: false,
    ).hasMatch(userAgent)
    ? 'v2box'
    : null;

bool subscriptionClientSupports(ClientEndpoint endpoint, String? client) {
  if (client != 'v2box') return true;
  // Only the protocols advertised by V2Box's publisher, with verified URI semantics.
  if (!{
    'vless',
    'vmess',
    'trojan',
    'shadowsocks',
    'hysteria2',
  }.contains(endpoint.protocolId))
    return false;
  if (endpoint.protocolId == 'hysteria2') {
    final options =
        jsonDecode(endpoint.settings['protocolOptions'] ?? '{}') as Map;
    if (!{'', 'salamander'}.contains(options['obfs'] ?? '')) return false;
  }
  return true;
}

List<ClientEndpoint> exportableEndpoints(
  ClientExporter exporter,
  List<ClientEndpoint> endpoints, {
  String? client,
}) => endpoints
    .where(
      (endpoint) =>
          exporter.canExport([endpoint]) &&
          subscriptionClientSupports(endpoint, client),
    )
    .toList();

/// Clash client format. Inputs describe protocol semantics, never a server-core configuration.
class ClashExporter implements ClientExporter {
  @override
  String get format => 'clash';
  @override
  List<ClientExportRestriction> get restrictions => compatibilityRestrictions;
  static const compatibilityRestrictions = <ClientExportRestriction>[
    ClientExportRestriction(
      protocolIds: ['http', 'socks', 'mixed'],
      format: 'clash',
      when: {
        'security': ['REALITY'],
      },
    ),
    ClientExportRestriction(
      protocolIds: ['trojan', 'anytls'],
      format: 'clash',
      when: {
        'security': ['None'],
      },
    ),
    ClientExportRestriction(
      protocolIds: ['vless', 'vmess', 'trojan'],
      format: 'clash',
      when: {
        'transport': ['WebSocket'],
        'security': ['REALITY'],
      },
    ),
  ];
  static const supported = {
    'vless',
    'vmess',
    'trojan',
    'shadowsocks',
    'snell',
    'anytls',
    'hysteria2',
    'tuic',
    'tuic-v4',
    'mieru',
    'sudoku',
    'trusttunnel',
    'shadowquic',
    'http',
    'socks',
    'mixed',
    'amneziawg',
  };
  List<ClientEndpoint> _entries(List<ClientEndpoint> endpoints) {
    if (endpoints.isEmpty)
      throw const ApiException('access_empty', status: 409);
    for (final endpoint in endpoints) {
      if (!supported.contains(endpoint.protocolId) ||
          !compatible(endpoint.protocolId, endpoint.settings))
        throw const ApiException('export_unavailable', status: 422);
    }
    return endpoints;
  }

  @override
  bool canExport(List<ClientEndpoint> endpoints) {
    try {
      _entries(endpoints);
      return true;
    } on ApiException {
      return false;
    }
  }

  static bool compatible(String protocol, Map<String, String> settings) {
    if (!{
          'None',
          'TLS',
          'REALITY',
          'Built-in',
        }.contains(settings['security']) &&
        !(protocol == 'shadowquic' && settings['security'] == 'JLS'))
      return false;
    if ({'mKCP', 'Mekya', 'KCP'}.contains(settings['transport'])) return false;
    return !compatibilityRestrictions.any(
      (rule) => rule.protocolIds.contains(protocol) && rule.matches(settings),
    );
  }

  @override
  String profile(List<ClientEndpoint> endpoints) {
    final proxies = <Map<String, Object?>>[], names = <String>{};
    for (final endpoint in _entries(endpoints)) {
      var name = endpoint.name;
      while (!names.add(name)) name = '$name · ${endpoint.id}';
      proxies.add(_proxy(endpoint, name));
    }
    var group = 'Sky UI';
    while (names.contains(group)) {
      group = '$group ·';
    }
    return '${const JsonEncoder.withIndent('  ').convert({
      'mixed-port': 7890,
      'allow-lan': false,
      'mode': 'rule',
      'log-level': 'info',
      'proxies': proxies,
      'proxy-groups': [
        {'name': group, 'type': 'select', 'proxies': names.toList()},
      ],
      'rules': ['MATCH,$group'],
    })}\n';
  }

  Map<String, Object?> _proxy(ClientEndpoint c, String name) {
    final s = c.settings, k = c.credentials, id = c.protocolId;
    final out = <String, Object?>{
      'name': name,
      'type': id == 'mixed' || id == 'socks'
          ? 'socks5'
          : id == 'tuic-v4'
          ? 'tuic'
          : id == 'shadowsocks'
          ? 'ss'
          : id == 'amneziawg'
          ? 'wireguard'
          : id,
      'server': c.server,
      'port': c.port,
    };
    final options = s['protocolOptions'] == null
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(s['protocolOptions']!) as Map);
    out.addAll(options);
    if (!{'None', 'Built-in'}.contains(s['security'])) {
      out[{'vless', 'vmess'}.contains(id) ? 'servername' : 'sni'] =
          s['serverName'];
      if ({'vless', 'vmess', 'trojan', 'anytls'}.contains(id))
        out['client-fingerprint'] = s['clientFingerprint'] ?? 'chrome';
    }
    if (s['clientAlpn']?.isNotEmpty == true)
      out['alpn'] = s['clientAlpn']!
          .split('\n')
          .where((v) => v.isNotEmpty)
          .toList();
    switch (id) {
      case 'amneziawg':
        out.addAll({
          'ip': k['address']!.split('/').first,
          'private-key': k['privateKey'],
          'public-key': k['serverPublicKey'],
          'pre-shared-key': k['presharedKey'],
          'udp': true,
          'mtu': int.parse(s['mtu'] ?? '1280'),
          'remote-dns-resolve': true,
          'dns': (s['dns'] ?? '').split('\n'),
          'amnezia-wg-option': {
            'version': 3,
            'header-protection-key': k['headerProtectionKey'],
            for (final e in s.entries.where(
              (e) => e.key.startsWith('awg.') && e.value.isNotEmpty,
            ))
              _awgOption(e.key.substring(4)): e.value == 'true'
                  ? true
                  : e.value == 'false'
                  ? false
                  : int.tryParse(e.value) ?? e.value,
          },
        });
      case 'vless' || 'vmess':
        out['uuid'] = k['uuid'];
        out['network'] = switch (s['transport']) {
          'WebSocket' => 'ws',
          'gRPC' => 'grpc',
          'XHTTP' => 'xhttp',
          _ => 'tcp',
        };
        out['udp'] = true;
        out['packet-encoding'] = 'xudp';
        if (id == 'vless') {
          if (s['flow'] != null && s['flow'] != 'None') out['flow'] = s['flow'];
        } else {
          out['alterId'] = int.tryParse(s['alterId'] ?? '0') ?? 0;
          out['cipher'] = s['clientCipher'] ?? 'auto';
        }
        if (s['websocketPath'] != null)
          out['ws-opts'] = {
            'path': s['websocketPath'],
            if ((s['websocketHost'] ?? '').isNotEmpty)
              'headers': {'Host': s['websocketHost']},
          };
        if (s['grpcServiceName'] != null)
          out['grpc-opts'] = {'grpc-service-name': s['grpcServiceName']};
        if (s['xhttpOptions'] != null)
          out['xhttp-opts'] = jsonDecode(s['xhttpOptions']!);
      case 'trojan' || 'anytls' || 'hysteria2':
        out['password'] = k['password'];
        out['udp'] = true;
        if (id == 'trojan') {
          out['network'] = switch (s['transport']) {
            'WebSocket' => 'ws',
            'gRPC' => 'grpc',
            _ => 'tcp',
          };
          if (s['websocketPath'] != null)
            out['ws-opts'] = {
              'path': s['websocketPath'],
              if ((s['websocketHost'] ?? '').isNotEmpty)
                'headers': {'Host': s['websocketHost']},
            };
          if (s['grpcServiceName'] != null)
            out['grpc-opts'] = {'grpc-service-name': s['grpcServiceName']};
        }
      case 'shadowsocks':
        out['cipher'] = s['cipher'];
        out['password'] = k['password'];
        out['udp'] = s['udp'] != 'false';
      case 'snell':
        out['psk'] = k['password'];
        out['version'] = int.parse(s['version'] ?? '4');
        out['udp'] = int.parse(s['version'] ?? '4') >= 3 && s['udp'] != 'false';
      case 'tuic':
        out['uuid'] = k['uuid'];
        out['password'] = k['password'];
      case 'tuic-v4':
        out['token'] = k['password'];
      case 'mieru':
        out['username'] = k['username'];
        out['password'] = k['password'];
        out['transport'] = s['transport'];
        out['udp'] = true;
      case 'sudoku':
        out['key'] = k['sudokuKey'];
      case 'shadowquic':
        out['username'] = k['shadowQuicUsername'];
        out['password'] = k['password'];
        out['sni'] = s['serverName'];
      case 'trusttunnel':
        out['username'] = k['username'];
        out['password'] = k['password'];
        out['udp'] = true;
        out['quic'] = s['transport'] != 'TCP';
      case 'http' || 'socks' || 'mixed':
        out['username'] = k['username'];
        out['password'] = k['password'];
        if (id != 'http') out['udp'] = s['udp'] != 'false';
    }
    if (s['security'] == 'TLS' || s['security'] == 'REALITY') {
      if ({'vless', 'vmess', 'trojan', 'http', 'socks', 'mixed'}.contains(id))
        out['tls'] = true;
      out[{'vless', 'vmess'}.contains(id) ? 'servername' : 'sni'] =
          s['serverName'];
      if (k['fingerprint'] != null) out['fingerprint'] = k['fingerprint'];
      if ({'vless', 'vmess', 'trojan', 'anytls'}.contains(id))
        out['client-fingerprint'] = s['clientFingerprint'] ?? 'chrome';
      if (s['security'] == 'REALITY')
        out['reality-opts'] = {
          'public-key': k['publicKey'],
          'short-id': k['shortId'],
          if (s['realityMlkem'] == 'true') 'support-x25519mlkem768': true,
        };
    }
    return out;
  }

  @override
  List<ShareLink> links(List<ClientEndpoint> endpoints) =>
      ShareUriCodec().links(_entries(endpoints));
}

String _awgOption(String name) => name
    .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]}-${m[2]}')
    .toLowerCase();

String amneziaProfile(ClientEndpoint endpoint) {
  final s = endpoint.settings, k = endpoint.credentials;
  final authority = Uri(
    scheme: 'udp',
    host: endpoint.server,
    port: endpoint.port,
  ).authority;
  return '[Interface]\nPrivateKey = ${k['privateKey']}\nAddress = ${k['address']}\nDNS = ${(s['dns'] ?? '').split('\n').join(', ')}\nMTU = ${s['mtu']}\n'
      'HeaderProtectionKey = ${k['headerProtectionKey']}\n'
      '${s.entries.where((e) => e.key.startsWith('awg.') && e.value.isNotEmpty).map((e) => '${e.key.substring(4)} = ${e.value == 'true'
          ? 'on'
          : e.value == 'false'
          ? 'off'
          : e.value}').join('\n')}\n\n'
      '[Peer]\nPublicKey = ${k['serverPublicKey']}\nPresharedKey = ${k['presharedKey']}\nEndpoint = $authority\nAllowedIPs = 0.0.0.0/0, ::/0\nPersistentKeepalive = ${s['keepalive']}\n';
}

/// Individual protocol URIs reused by independent client subscription formats.
class ShareUriCodec {
  List<ShareLink> links(List<ClientEndpoint> endpoints) {
    final links = <ShareLink>[];
    for (final c in endpoints) {
      final s = c.settings, k = c.credentials, id = c.protocolId;
      if (id == 'amneziawg') {
        links.add(
          ShareLink(
            name: c.name,
            uri: '',
            content: amneziaProfile(c),
            filename: 'Sky-UI-${c.id}.conf',
          ),
        );
        continue;
      }
      if (k['fingerprint'] != null || k['clientCertificate'] != null) continue;
      if ((s['clientAlpn'] ?? '').isNotEmpty &&
          !{'vless', 'trojan'}.contains(id))
        continue;
      if (s['xhttpOptions'] != null &&
          (jsonDecode(s['xhttpOptions']!) as Map).keys.any(
            (key) => !{'path', 'mode', 'host'}.contains(key),
          ))
        continue;
      if (s['protocolOptions'] != null && (id == 'hysteria2' || id == 'tuic')) {
        final represented = id == 'hysteria2'
            ? {'obfs', 'obfs-password'}
            : {'congestion-controller'};
        if ((jsonDecode(s['protocolOptions']!) as Map).keys.any(
          (key) => !represented.contains(key),
        ))
          continue;
      }
      if (!{'None', 'TLS', 'REALITY', 'Built-in'}.contains(s['security']))
        continue;
      String? uri;
      if (id == 'vless' || id == 'trojan') {
        final params = <String, String>{
          if (id == 'vless') 'encryption': 'none',
          'security': s['security'] == 'REALITY'
              ? 'reality'
              : s['security'] == 'TLS'
              ? 'tls'
              : 'none',
          'type': switch (s['transport']) {
            'WebSocket' => 'ws',
            'gRPC' => 'grpc',
            'XHTTP' => 'xhttp',
            _ => 'tcp',
          },
          if (s['security'] != 'None') 'sni': s['serverName'] ?? '',
          if (s['security'] != 'None') 'fp': s['clientFingerprint'] ?? 'chrome',
          if (s['security'] == 'REALITY') 'pbk': k['publicKey']!,
          if (s['security'] == 'REALITY') 'sid': k['shortId']!,
          if (s['flow'] != null && s['flow'] != 'None') 'flow': s['flow']!,
          if (s['websocketPath'] != null) 'path': s['websocketPath']!,
          if ((s['websocketHost'] ?? '').isNotEmpty)
            'host': s['websocketHost']!,
          if ((s['clientAlpn'] ?? '').isNotEmpty)
            'alpn': s['clientAlpn']!.split('\n').join(','),
          if (s['grpcServiceName'] != null)
            'serviceName': s['grpcServiceName']!,
        };
        if (s['xhttpOptions'] != null) {
          final x = jsonDecode(s['xhttpOptions']!) as Map;
          params['path'] = x['path'] as String? ?? '/';
          params['mode'] = x['mode'] as String? ?? 'auto';
          if (x['host'] is String && (x['host'] as String).isNotEmpty)
            params['host'] = x['host'] as String;
        }
        uri = Uri(
          scheme: id,
          userInfo: id == 'vless' ? k['uuid']! : k['password']!,
          host: c.server,
          port: c.port,
          queryParameters: params,
          fragment: c.name,
        ).toString();
      } else if (id == 'shadowsocks' &&
          s['transport'] == 'TCP' &&
          s['simpleObfs'] == null) {
        uri = Uri(
          scheme: 'ss',
          userInfo: base64Url
              .encode(utf8.encode('${s['cipher']}:${k['password']}'))
              .replaceAll('=', ''),
          host: c.server,
          port: c.port,
          fragment: c.name,
        ).toString();
      } else if (id == 'vmess' &&
          {'None', 'TLS'}.contains(s['security']) &&
          {'TCP', 'WebSocket', 'gRPC'}.contains(s['transport'])) {
        uri =
            'vmess://${base64.encode(utf8.encode(jsonEncode({'v': '2', 'ps': c.name, 'add': c.server, 'port': '${c.port}', 'id': k['uuid'], 'aid': s['alterId'] ?? '0', 'scy': s['clientCipher'] ?? 'auto', 'net': s['transport'] == 'WebSocket'
                ? 'ws'
                : s['transport'] == 'gRPC'
                ? 'grpc'
                : 'tcp', 'type': 'none', 'host': '', 'path': s['websocketPath'] ?? s['grpcServiceName'] ?? '', 'tls': s['security'] == 'TLS' ? 'tls' : '', 'sni': s['serverName'] ?? ''})))}';
      } else if (id == 'hysteria2') {
        uri = Uri(
          scheme: 'hysteria2',
          userInfo: k['password']!,
          host: c.server,
          port: c.port,
          queryParameters: {
            'sni': s['serverName'] ?? '',
            if (s['protocolOptions'] != null &&
                ((jsonDecode(s['protocolOptions']!) as Map)['obfs'] ?? '') !=
                    '')
              ...Map.fromEntries(
                (jsonDecode(s['protocolOptions']!) as Map).entries.where(
                  (e) => {'obfs', 'obfs-password'}.contains(e.key),
                ),
              ).map((k, v) => MapEntry(k as String, v.toString())),
          },
          fragment: c.name,
        ).toString();
      } else if (id == 'tuic') {
        uri = Uri(
          scheme: 'tuic',
          userInfo: '${k['uuid']}:${k['password']}',
          host: c.server,
          port: c.port,
          queryParameters: {
            'sni': s['serverName'] ?? '',
            'congestion_control':
                (jsonDecode(s['protocolOptions'] ?? '{}')
                        as Map)['congestion-controller']
                    as String? ??
                'bbr',
          },
          fragment: c.name,
        ).toString();
      } else if (id == 'anytls' && s['security'] == 'TLS') {
        uri = Uri(
          scheme: 'anytls',
          userInfo: k['password']!,
          host: c.server,
          port: c.port,
          queryParameters: {'sni': s['serverName'] ?? ''},
          fragment: c.name,
        ).toString();
      } else if (id == 'naive') {
        uri = Uri(
          scheme: s['transport'] == 'HTTP/3' ? 'naive+quic' : 'naive+https',
          userInfo: '${k['username']}:${k['password']}',
          host: s['serverName']?.isNotEmpty == true
              ? s['serverName']
              : c.server,
          port: c.port,
          fragment: c.name,
        ).toString();
      } else if (id == 'http' || id == 'socks' || id == 'mixed') {
        uri = Uri(
          scheme: id == 'http'
              ? (s['security'] == 'TLS' ? 'https' : 'http')
              : 'socks5',
          userInfo: '${k['username']}:${k['password']}',
          host: c.server,
          port: c.port,
          fragment: c.name,
        ).toString();
        if (id != 'http' && s['security'] == 'TLS') uri = null;
      }
      if (uri != null) links.add(ShareLink(name: c.name, uri: uri));
    }
    return links;
  }
}

/// Base64 URI subscription for V2Ray clients such as V2Box.
class V2RayExporter implements ClientExporter {
  @override
  String get format => 'v2ray';
  @override
  List<ClientExportRestriction> get restrictions => const [];
  static const protocols = {
    'vless',
    'vmess',
    'trojan',
    'shadowsocks',
    'hysteria2',
    'tuic',
    'naive',
  };

  @override
  bool canExport(List<ClientEndpoint> endpoints) {
    if (endpoints.isEmpty ||
        endpoints.any((e) => !protocols.contains(e.protocolId)))
      return false;
    return ShareUriCodec().links(endpoints).length == endpoints.length;
  }

  @override
  List<ShareLink> links(List<ClientEndpoint> endpoints) {
    if (!canExport(endpoints))
      throw const ApiException('export_unavailable', status: 422);
    return ShareUriCodec().links(endpoints);
  }

  @override
  String profile(List<ClientEndpoint> endpoints) => base64.encode(
    utf8.encode('${links(endpoints).map((e) => e.uri).join('\n')}\n'),
  );
}
