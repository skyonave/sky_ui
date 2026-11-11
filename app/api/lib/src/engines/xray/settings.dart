import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../application/core_settings/form.dart';
import '../domain_pattern.dart';
import '../proxy/routing_geodata.dart';
import '../../shared/api_exception.dart';
import '../proxy/relay_outbounds.dart';

/// Xray's built-in DNS and field routing retain their native semantics.
class XraySettings {
  static const directTag = 'sky-ui/settings/direct',
      rejectTag = 'sky-ui/settings/reject';
  static final fields = CoreSettingsForm.fields(
    logLevels: ['none', 'error', 'warning', 'info', 'debug'],
    defaultLogLevel: 'warning',
    resolverHelp: 'coreSettings.help.xray.resolvers',
    logHelp: 'coreSettings.help.xray.logLevel',
  );
  static Map<String, String> read(String text, Map<String, String>? stored) {
    final log = CoreSettingsForm.document(text)['log'] as Map? ?? {};
    return CoreSettingsForm.read(
      fields,
      log['loglevel'] as String? ?? 'warning',
      stored,
    );
  }

  static Map<String, String> prepare(
    String text,
    Map<String, String>? stored,
    Map<String, String> input,
  ) {
    final values = CoreSettingsForm.validate(
      fields,
      read(text, stored),
      input,
      schemes: ['https', 'udp', 'tcp'],
    );
    if (values['dnsMode'] == 'custom' &&
        CoreSettingsForm.lines(values['resolvers']!).any((value) {
          if (InternetAddress.tryParse(value) != null) return false;
          final uri = Uri.parse(value);
          return uri.scheme != 'https' &&
              InternetAddress.tryParse(uri.host) == null;
        }))
      throw const ApiException(
        'settings_unsupported',
        status: 422,
        fields: {'resolvers': 'format_invalid'},
      );
    final base = CoreSettingsForm.document(text);
    values['_baseline'] =
        stored?['_baseline'] ??
        jsonEncode({
          for (final key in ['dns', 'routing', 'log'])
            if (base.containsKey(key)) key: base[key],
        });
    return values;
  }

  static Object _resolver(String value) {
    if (InternetAddress.tryParse(value) != null) return value;
    final uri = Uri.parse(value);
    if (uri.scheme == 'udp')
      return {'address': uri.host, 'port': uri.hasPort ? uri.port : 53};
    return uri.replace(scheme: '${uri.scheme}+local').toString();
  }

  static void apply(
    Map<String, dynamic> base,
    List<String> tags,
    Map<String, String>? values, {
    Map<String, NodeRouting> policies = const {},
    Map<String, Map<String, String>> relays = const {},
  }) {
    if (values == null) return;
    final original = jsonDecode(values['_baseline']!) as Map;
    final log = Map<String, dynamic>.from(original['log'] as Map? ?? {});
    log['loglevel'] = values['logLevel'];
    if (values['logLevel'] == 'none') {
      log['access'] = 'none';
      log['error'] = 'none';
    }
    base['log'] = log;
    final routing = Map<String, dynamic>.from(
      original['routing'] as Map? ?? {},
    );
    final rows = jsonDecode(values['accessRules']!) as List;
    final resolveIp =
        values['blockPrivate'] == 'true' ||
        rows.any((r) => r['type'] == 'cidr');
    final policyResolveIp =
        relays.isNotEmpty ||
        policies.values.any(
          (policy) => policy.rules.any((rule) => rule.matchesIp),
        );
    final customDns = values['dnsMode'] != 'existing';
    final privateTags = values['blockPrivate'] == 'true'
        ? tags
        : relays.keys.toList();
    final allowed = ProxyRelayOutbounds.allowedTargets(tags, relays, directTag);
    final active =
        values['blockPrivate'] == 'true' ||
        rows.isNotEmpty ||
        policies.isNotEmpty;
    final originalRules = (routing['rules'] as List? ?? []);
    final foreign = (base['inbounds'] as List).any(
      (i) => i is Map && !(i['tag']?.toString().startsWith('sky-') ?? false),
    );
    bool hasIpRule(Object? node) => node is Map
        ? node.containsKey('ip') || node.values.any(hasIpRule)
        : node is List && node.any(hasIpRule);
    if ((active && (routing['script']?.toString().isNotEmpty ?? false)) ||
        ((resolveIp || policyResolveIp) &&
            foreign &&
            routing['domainStrategy'] != 'IPOnDemand' &&
            hasIpRule(originalRules)))
      throw const ApiException('core_settings_routing_conflict', status: 422);
    if (original.containsKey('dns')) {
      base['dns'] = original['dns'];
    } else {
      base.remove('dns');
    }
    if (customDns || ((resolveIp || policyResolveIp) && base['dns'] == null)) {
      base['dns'] = {
        'servers': values['dnsMode'] == 'custom'
            ? CoreSettingsForm.lines(
                values['resolvers']!,
              ).map(_resolver).toList()
            : ['localhost'],
        if ((original['dns'] as Map?)?['hosts'] != null)
          'hosts': (original['dns'] as Map)['hosts'],
      };
    }
    if ((resolveIp || policyResolveIp) && tags.isNotEmpty) {
      routing['domainStrategy'] = 'IPOnDemand';
    }
    final outbounds = List<dynamic>.from(
      (base['outbounds'] as List)
          .where((o) => o is! Map || ![directTag, rejectTag].contains(o['tag']))
          .toList(),
    );
    final ownsDirect =
        tags.isNotEmpty &&
        (customDns || resolveIp || rows.any((r) => r['action'] == 'allow'));
    if (ownsDirect || policies.isNotEmpty)
      outbounds.add({
        'protocol': 'freedom',
        'tag': directTag,
        if (ownsDirect || policyResolveIp)
          'settings': {'domainStrategy': 'UseIP'},
      });
    if (tags.isNotEmpty && active)
      outbounds.add({'protocol': 'blackhole', 'tag': rejectTag});
    base['outbounds'] = outbounds;
    final prefix = <Map<String, Object?>>[
      if (tags.isNotEmpty) ...[
        if (privateTags.isNotEmpty)
          {
            'type': 'field',
            'inboundTag': privateTags,
            // Xray unmaps IPv4-mapped IPv6 before matching IPv4 CIDRs.
            'ip': CoreSettingsForm.privateNetworks
                .where((net) => net != '::ffff:0:0/96')
                .toList(),
            'outboundTag': rejectTag,
          },
        for (final row in rows)
          for (final target
              in (row['action'] == 'allow' ? allowed : {rejectTag: tags})
                  .entries)
            {
              'type': 'field',
              'inboundTag': target.value,
              row['type'] == 'domain' ? 'domain' : 'ip': [
                row['type'] == 'domain'
                    ? 'domain:${row['target']}'
                    : row['target'],
              ],
              'outboundTag': target.key,
            },
        for (final e in policies.entries) ...[
          for (final rule in e.value.rules)
            _policyRule(e.key, rule.action, relays[e.key], _match(rule)),
          _policyRule(e.key, e.value.fallback, relays[e.key], const {
            'network': 'tcp,udp',
          }),
        ],
      ],
    ];
    if (prefix.isNotEmpty || ownsDirect)
      routing['rules'] = [
        ...prefix,
        ...originalRules,
        if (ownsDirect)
          {
            'type': 'field',
            'inboundTag': tags,
            'network': 'tcp,udp',
            'outboundTag': directTag,
          },
      ];
    if (routing.isNotEmpty) {
      base['routing'] = routing;
    } else {
      base.remove('routing');
    }
  }

  static Map<String, Object?> _match(RoutingRule rule) {
    final targets = rule.targets;
    return switch (rule.type) {
      'domain' => {
        'domain': [for (final value in targets) 'full:$value'],
      },
      'suffix' => {
        'domain': [for (final value in targets) 'domain:$value'],
      },
      'keyword' => {'domain': targets},
      'wildcard' => {
        'domain': [
          for (final value in targets) 'regexp:${domainPattern(value)}',
        ],
      },
      'geosite' => {
        'domain': [
          for (final value in targets)
            'ext:${RoutingGeoData.xrayAsset('geosite')}:$value',
        ],
      },
      'geoip' => {
        'ip': [
          for (final value in targets)
            'ext:${RoutingGeoData.xrayAsset('geoip')}:$value',
        ],
      },
      'cidr' => {'ip': targets},
      'port' => {'port': targets.join(',')},
      'network' => {'network': rule.target},
      _ => throw StateError('Invalid routing match type'),
    };
  }

  static Map<String, Object?> _policyRule(
    String tag,
    String action,
    Map<String, String>? relay,
    Map<String, Object?> match,
  ) => {
    'type': 'field',
    'inboundTag': [tag],
    ...match,
    'outboundTag': action == NodeRouting.block
        ? rejectTag
        : ProxyRelayOutbounds.target(relay, action, directTag),
  };
}
