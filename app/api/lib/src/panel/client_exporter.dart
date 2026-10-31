import 'dart:convert';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import '../errors.dart';
import 'domain.dart';

abstract interface class ClientExporter {
  String get format;
  String profile(List<ClientEndpoint> endpoints);
  List<ShareLink> links(List<ClientEndpoint> endpoints);
}

// This client format is independent of the installed server-core adapter.
class ClashExporter implements ClientExporter {
  @override
  String get format => 'clash';
  List<ClientEndpoint> _entries(List<ClientEndpoint> endpoints) {
    if (endpoints.isEmpty)
      throw const ApiException('access_empty', status: 409);
    if (endpoints.any(
      (c) =>
          c.protocolId != 'vless' ||
          c.settings['transport'] != 'TCP' ||
          c.settings['security'] != 'REALITY',
    )) {
      throw const ApiException('export_unavailable', status: 422);
    }
    return endpoints;
  }

  @override
  String profile(List<ClientEndpoint> endpoints) {
    final entries = _entries(endpoints);
    final names = <String>{};
    final proxies = <Map<String, Object?>>[];
    for (final c in entries) {
      final s = c.settings;
      var name = c.name;
      while (!names.add(name)) {
        name = '$name · ${c.id}';
      }
      proxies.add({
        'name': name,
        'type': 'vless',
        'server': c.server,
        'port': c.port,
        'uuid': c.credentials['uuid'],
        'network': 'tcp',
        'tls': true,
        'udp': true,
        'packet-encoding': 'xudp',
        'servername': s['serverName'],
        'client-fingerprint': 'chrome',
        'reality-opts': {
          'public-key': c.credentials['publicKey'],
          'short-id': c.credentials['shortId'],
        },
        if (s['flow'] != 'None') 'flow': s['flow'],
      });
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

  @override
  List<ShareLink> links(List<ClientEndpoint> endpoints) => [
    for (final c in _entries(endpoints))
      ShareLink(
        name: c.name,
        uri: Uri(
          scheme: 'vless',
          userInfo: c.credentials['uuid']!,
          host: c.server,
          port: c.port,
          queryParameters: {
            'encryption': 'none',
            'security': 'reality',
            'sni': c.settings['serverName']!,
            'fp': 'chrome',
            'pbk': c.credentials['publicKey']!,
            'sid': c.credentials['shortId']!,
            'type': 'tcp',
            if (c.settings['flow'] != 'None') 'flow': c.settings['flow']!,
          },
          fragment: c.name,
        ).toString(),
      ),
  ];
}
