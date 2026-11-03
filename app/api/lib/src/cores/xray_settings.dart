import 'dart:convert';
import 'dart:io';
import '../errors.dart';
import '../panel/core_settings_form.dart';

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
    Map<String, String>? values,
  ) {
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
    final customDns = values['dnsMode'] != 'existing';
    final active = values['blockPrivate'] == 'true' || rows.isNotEmpty;
    final originalRules = (routing['rules'] as List? ?? []);
    final foreign = (base['inbounds'] as List).any(
      (i) => i is Map && !(i['tag']?.toString().startsWith('sky-') ?? false),
    );
    bool hasIpRule(Object? node) => node is Map
        ? node.containsKey('ip') || node.values.any(hasIpRule)
        : node is List && node.any(hasIpRule);
    if ((active && (routing['script']?.toString().isNotEmpty ?? false)) ||
        (resolveIp &&
            foreign &&
            routing['domainStrategy'] != 'IPOnDemand' &&
            hasIpRule(originalRules)))
      throw const ApiException('core_settings_routing_conflict', status: 422);
    if (original.containsKey('dns')) {
      base['dns'] = original['dns'];
    } else {
      base.remove('dns');
    }
    if (customDns || (resolveIp && base['dns'] == null)) {
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
    if (resolveIp && tags.isNotEmpty) routing['domainStrategy'] = 'IPOnDemand';
    final outbounds = List<dynamic>.from(
      (base['outbounds'] as List)
          .where((o) => o is! Map || ![directTag, rejectTag].contains(o['tag']))
          .toList(),
    );
    final ownsDirect =
        tags.isNotEmpty &&
        (customDns || resolveIp || rows.any((r) => r['action'] == 'allow'));
    if (ownsDirect)
      outbounds.add({
        'protocol': 'freedom',
        'tag': directTag,
        'settings': {'domainStrategy': 'UseIP'},
      });
    if (tags.isNotEmpty && active)
      outbounds.add({'protocol': 'blackhole', 'tag': rejectTag});
    base['outbounds'] = outbounds;
    final prefix = <Map<String, Object?>>[
      if (tags.isNotEmpty) ...[
        if (values['blockPrivate'] == 'true')
          {
            'type': 'field',
            'inboundTag': tags,
            // Xray unmaps IPv4-mapped IPv6 before matching IPv4 CIDRs.
            'ip': CoreSettingsForm.privateNetworks
                .where((net) => net != '::ffff:0:0/96')
                .toList(),
            'outboundTag': rejectTag,
          },
        for (final row in rows)
          {
            'type': 'field',
            'inboundTag': tags,
            row['type'] == 'domain' ? 'domain' : 'ip': [
              row['type'] == 'domain'
                  ? 'domain:${row['target']}'
                  : row['target'],
            ],
            'outboundTag': row['action'] == 'allow' ? directTag : rejectTag,
          },
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
}
