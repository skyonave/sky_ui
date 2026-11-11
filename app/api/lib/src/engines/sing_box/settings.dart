import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../application/core_settings/form.dart';
import '../proxy/relay_outbounds.dart';

/// sing-box 1.14 typed DNS transports and scoped route actions.
class SingBoxSettings {
  static const directTag = 'sky-ui/settings/direct';
  static const systemTag = 'sky-ui/settings/system-dns';
  static const upstreamTag = 'sky-ui/settings/upstream-dns';
  static final fields = CoreSettingsForm.fields(
    logLevels: [
      'disabled',
      'panic',
      'fatal',
      'error',
      'warn',
      'info',
      'debug',
      'trace',
    ],
    defaultLogLevel: 'info',
    singleResolver: true,
    resolverHelp: 'coreSettings.help.sing-box.resolvers',
    logHelp: 'coreSettings.help.sing-box.logLevel',
  );

  static Map<String, String> read(String text, Map<String, String>? stored) {
    final log = CoreSettingsForm.document(text)['log'] as Map? ?? {};
    return CoreSettingsForm.read(
      fields,
      log['disabled'] == true ? 'disabled' : log['level'] as String? ?? 'info',
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
      maxResolvers: 1,
    );
    final base = CoreSettingsForm.document(text);
    values['_baseline'] =
        stored?['_baseline'] ??
        jsonEncode({
          for (final k in ['dns', 'route'])
            if (base.containsKey(k)) k: base[k],
        });
    return values;
  }

  static Map<String, Object?> _resolver(String value) {
    final ip = InternetAddress.tryParse(value);
    final uri = ip != null ? null : Uri.parse(value);
    final host = ip?.address ?? uri!.host;
    final type = uri?.scheme ?? 'udp';
    return {
      'type': type,
      'tag': upstreamTag,
      'server': host,
      if (uri?.hasPort == true) 'server_port': uri!.port,
      if (type == 'https') 'path': uri!.path.isEmpty ? '/dns-query' : uri.path,
      if (InternetAddress.tryParse(host) == null) 'domain_resolver': systemTag,
    };
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
    final log = Map<String, dynamic>.from(base['log'] as Map? ?? {});
    log['disabled'] = values['logLevel'] == 'disabled';
    if (values['logLevel'] != 'disabled') log['level'] = values['logLevel'];
    base['log'] = log;
    final route = Map<String, dynamic>.from(original['route'] as Map? ?? {});
    final rows = jsonDecode(values['accessRules']!) as List;
    final resolveIp =
        values['blockPrivate'] == 'true' ||
        rows.any((r) => r['type'] == 'cidr');
    final customDns = values['dnsMode'] != 'existing';
    final resolveTags = resolveIp || customDns
        ? tags
        : {
            ...relays.keys,
            for (final e in policies.entries)
              if (e.value.rules.any((rule) => rule.type == 'cidr')) e.key,
          }.toList();
    final privateTags = values['blockPrivate'] == 'true'
        ? tags
        : relays.keys.toList();
    final allowed = ProxyRelayOutbounds.allowedTargets(tags, relays, directTag);
    if (original.containsKey('dns')) {
      base['dns'] = original['dns'];
    } else {
      base.remove('dns');
    }
    String? server;
    if (customDns ||
        (resolveTags.isNotEmpty &&
            (((base['dns'] as Map? ?? {})['servers'] as List?) ?? [])
                .isEmpty)) {
      server = values['dnsMode'] == 'custom' ? upstreamTag : systemTag;
      base['dns'] = {
        'servers': [
          {'type': 'local', 'tag': systemTag},
          if (values['dnsMode'] == 'custom') _resolver(values['resolvers']!),
        ],
        'final': server,
      };
      route['default_domain_resolver'] = server;
    }
    final prefix = <Map<String, Object?>>[
      if (tags.isNotEmpty) ...[
        if (resolveTags.isNotEmpty)
          {
            'inbound': resolveTags,
            'action': 'resolve',
            if (server != null) 'server': server,
          },
        if (privateTags.isNotEmpty)
          {
            'inbound': privateTags,
            'ip_cidr': CoreSettingsForm.privateNetworks,
            'action': 'reject',
          },
        for (final row in rows)
          for (final target
              in (row['action'] == 'allow' ? allowed : {'': tags}).entries)
            {
              'inbound': target.value,
              row['type'] == 'domain' ? 'domain_suffix' : 'ip_cidr': [
                row['target'],
              ],
              'action': target.key.isEmpty ? 'reject' : 'route',
              if (target.key.isNotEmpty) 'outbound': target.key,
            },
        for (final e in policies.entries) ...[
          for (final rule in e.value.rules)
            _policyRule(e.key, rule.action, relays[e.key], {
              switch (rule.type) {
                'domain' => 'domain',
                'suffix' => 'domain_suffix',
                'cidr' => 'ip_cidr',
                'port' => 'port',
                _ => 'network',
              }: [
                rule.type == 'port' ? int.parse(rule.target) : rule.target,
              ],
            }),
          _policyRule(e.key, e.value.fallback, relays[e.key], const {}),
        ],
      ],
    ];
    if (prefix.isNotEmpty)
      route['rules'] = [...prefix, ...route['rules'] as List? ?? []];
    if (route.isNotEmpty) {
      base['route'] = route;
    } else {
      base.remove('route');
    }
    final outbounds = List<dynamic>.from(
      (base['outbounds'] as List)
          .where((o) => o is! Map || o['tag'] != directTag)
          .toList(),
    );
    if (tags.isNotEmpty &&
        (rows.any((r) => r['action'] == 'allow') || policies.isNotEmpty))
      outbounds.add({'type': 'direct', 'tag': directTag});
    base['outbounds'] = outbounds;
  }

  static Map<String, Object?> _policyRule(
    String tag,
    String action,
    Map<String, String>? relay,
    Map<String, Object?> match,
  ) => {
    'inbound': [tag],
    ...match,
    'action': action == NodeRouting.block ? 'reject' : 'route',
    if (action != NodeRouting.block)
      'outbound': ProxyRelayOutbounds.target(relay, action, directTag),
  };
}
