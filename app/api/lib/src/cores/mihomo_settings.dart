import 'dart:convert';
import 'package:yaml/yaml.dart';
import '../errors.dart';
import '../panel/core_settings_form.dart';

/// Settings owned by Sky UI; unrelated native sections are left intact.
class MihomoSettings {
  static const rulePrefix = 'sky-ui/access/';
  static final fields = CoreSettingsForm.fields(
    logLevels: ['silent', 'error', 'warning', 'info', 'debug'],
    defaultLogLevel: 'info',
  );

  static Map<String, dynamic> document(String text) {
    Object? plain(Object? v) => v is Map
        ? v.map((k, v) => MapEntry(k.toString(), plain(v)))
        : v is List
        ? v.map(plain).toList()
        : v;
    final value = plain(loadYaml(text));
    if (value is! Map<String, dynamic>)
      throw const ApiException('configuration_invalid', status: 422);
    return value;
  }

  static Map<String, String> read(String text, Map<String, String>? stored) {
    final base = document(text);
    return {
      for (final f in fields)
        f.id:
            stored?[f.id] ??
            (f.id == 'logLevel'
                ? (base['log-level'] as String? ?? 'info')
                : f.defaultValue),
    };
  }

  static List<String> lines(String value) => CoreSettingsForm.lines(value);

  static Map<String, String> prepare(
    String text,
    Map<String, String>? stored,
    Map<String, String> input,
  ) {
    final values = CoreSettingsForm.validate(fields, read(text, stored), input);
    final base = document(text);
    values['_baseline'] =
        stored?['_baseline'] ??
        jsonEncode({
          for (final key in ['dns', 'mode', 'rules'])
            if (base.containsKey(key)) key: base[key],
        });
    return values;
  }

  static const privateNetworks = CoreSettingsForm.privateNetworks;

  static void apply(
    Map<String, Object?> base,
    List<Map<String, Object?>> listeners,
    Map<String, String>? values,
  ) {
    if (values == null) return;
    final original = jsonDecode(values['_baseline']!) as Map;
    void restore(String key) {
      if (original.containsKey(key)) {
        base[key] = original[key];
      } else {
        base.remove(key);
      }
    }

    base['log-level'] = values['logLevel'];
    if (values['dnsMode'] == 'existing') {
      restore('dns');
    } else {
      final servers = values['dnsMode'] == 'system'
          ? ['system']
          : lines(values['resolvers']!);
      // Internal resolution only: no DNS listening socket is created.
      base['dns'] = {
        'enable': true,
        'enhanced-mode': 'redir-host',
        'use-hosts': true,
        'use-system-hosts': true,
        'ipv6': base['ipv6'] == true,
        'default-nameserver': ['system'],
        'nameserver': servers,
        'direct-nameserver': servers,
        'proxy-server-nameserver': servers,
      };
    }
    final currentSubRules = base['sub-rules'];
    if (currentSubRules != null && currentSubRules is! Map)
      throw const ApiException('configuration_invalid', status: 422);
    final subRules = <String, Object?>{
      if (currentSubRules is Map)
        for (final e in currentSubRules.entries)
          if (!e.key.toString().startsWith(rulePrefix))
            e.key.toString(): e.value,
    };
    final rows = jsonDecode(values['accessRules']!) as List;
    final active = values['blockPrivate'] == 'true' || rows.isNotEmpty;
    if (active) {
      final mode = original['mode'] ?? 'rule';
      // Changing global mode must not awaken previously bypassed foreign sub-rules.
      if (mode != 'rule' &&
          (base['listeners'] as List? ?? []).any(
            (l) =>
                l is Map &&
                !(l['name']?.toString().startsWith('sky-ui/') ?? false) &&
                (l['rule']?.toString().isNotEmpty ?? false),
          ))
        throw const ApiException('core_settings_routing_conflict', status: 422);
      base['mode'] = 'rule';
      if (mode == 'direct' || mode == 'global') {
        base['rules'] = ['MATCH,${mode == 'direct' ? 'DIRECT' : 'GLOBAL'}'];
      } else {
        restore('rules');
      }
      for (final listener in listeners) {
        final name = '$rulePrefix${listener['name']}';
        final fallbackRule = listener['rule']?.toString() ?? '';
        final fallbackProxy = listener['proxy']?.toString() ?? '';
        subRules[name] = <String>[
          if (values['blockPrivate'] == 'true')
            for (final net in privateNetworks)
              '${net.contains(':') ? 'IP-CIDR6' : 'IP-CIDR'},$net,REJECT',
          for (final row in rows)
            '${row['type'] == 'domain'
                ? 'DOMAIN-SUFFIX'
                : (row['target'] as String).contains(':')
                ? 'IP-CIDR6'
                : 'IP-CIDR'},${row['target']},${row['action'] == 'allow' ? 'DIRECT' : 'REJECT'}',
          if (fallbackProxy.isNotEmpty)
            'MATCH,$fallbackProxy'
          else if (fallbackRule.isNotEmpty)
            'SUB-RULE,(MATCH),$fallbackRule'
          else
            ...((base['rules'] as List?) ?? ['MATCH,DIRECT']).cast<String>(),
        ];
        listener.remove('proxy');
        listener['rule'] = name;
      }
    } else {
      restore('mode');
      restore('rules');
    }
    if (subRules.isEmpty) {
      base.remove('sub-rules');
    } else {
      base['sub-rules'] = subRules;
    }
  }
}
