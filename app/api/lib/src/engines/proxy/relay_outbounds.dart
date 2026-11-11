import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../application/access/records.dart';

class ProxyRelayOutbounds {
  static const _prefix = 'sky-ui/relay/';
  static const _method = '2022-blake3-aes-256-gcm';

  static Map<String, List<String>> allowedTargets(
    List<String> tags,
    Map<String, Map<String, String>> relays,
    String direct,
  ) {
    final result = <String, List<String>>{};
    for (final tag in tags) {
      final target = relays[tag]?[NodeRouting.next] ?? direct;
      result.putIfAbsent(target, () => []).add(tag);
    }
    return result;
  }

  static String target(
    Map<String, String>? relay,
    String action,
    String direct,
  ) => switch (action) {
    NodeRouting.direct => direct,
    NodeRouting.next => relay?[action] ?? direct,
    _ => relay![action]!,
  };

  static Map<String, Map<String, String>> apply(
    Map<String, dynamic> base,
    List<RelayLink> links, {
    required bool xray,
  }) {
    final outbounds = List<dynamic>.of(
      (base['outbounds'] as List).where(
        (item) =>
            item is! Map || item['tag']?.toString().startsWith(_prefix) != true,
      ),
    );
    final targets = <String, Map<String, String>>{};
    for (final link in links) {
      if (link.inbound)
        throw StateError('Unexpected inbound relay for proxy core');
      final actions = targets.putIfAbsent(link.connectionId, () => {});
      if (link.index == 0) actions[NodeRouting.next] = link.name;
      actions['${NodeRouting.nodePrefix}${link.targetNode}'] = link.name;
      outbounds.add(
        xray
            ? {
                'tag': link.name,
                'protocol': 'shadowsocks',
                'settings': {
                  'address': link.destination,
                  'port': link.port,
                  'method': _method,
                  'password': link.password,
                },
              }
            : {
                'tag': link.name,
                'type': 'shadowsocks',
                'server': link.destination,
                'server_port': link.port,
                'method': _method,
                'password': link.password,
              },
      );
    }
    base['outbounds'] = outbounds;
    return targets;
  }
}
