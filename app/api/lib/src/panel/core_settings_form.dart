import 'dart:convert';
import 'dart:io';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import '../errors.dart';

/// Shared form vocabulary and input validation, never a native engine document.
class CoreSettingsForm {
  static const _baseFields = <ProtocolField>[
    ProtocolField(
      'dnsMode',
      required: true,
      options: ['existing', 'system', 'custom'],
      defaultValue: 'existing',
      group: 'dns',
      labelKey: 'coreSettings.dnsMode',
      helpKey: 'coreSettings.help.dnsMode',
    ),
    ProtocolField(
      'resolvers',
      kind: 'lines',
      group: 'dns',
      maxLength: 4096,
      when: {
        'dnsMode': ['custom'],
      },
      required: true,
      labelKey: 'coreSettings.resolvers',
      helpKey: 'coreSettings.help.resolvers',
    ),
    ProtocolField(
      'blockPrivate',
      kind: 'boolean',
      defaultValue: 'false',
      group: 'access',
      labelKey: 'coreSettings.blockPrivate',
      helpKey: 'coreSettings.help.blockPrivate',
    ),
    ProtocolField(
      'accessRules',
      kind: 'rows',
      defaultValue: '[]',
      group: 'access',
      maxLength: 16384,
      labelKey: 'coreSettings.accessRules',
      helpKey: 'coreSettings.help.accessRules',
      children: [
        ProtocolField(
          'type',
          options: ['domain', 'cidr'],
          defaultValue: 'domain',
          labelKey: 'coreSettings.ruleType',
          helpKey: 'coreSettings.help.ruleType',
        ),
        ProtocolField(
          'target',
          required: true,
          labelKey: 'coreSettings.target',
          helpKey: 'coreSettings.help.target',
        ),
        ProtocolField(
          'action',
          options: ['block', 'allow'],
          defaultValue: 'block',
          labelKey: 'coreSettings.ruleAction',
          helpKey: 'coreSettings.help.ruleAction',
        ),
      ],
    ),
    ProtocolField(
      'logLevel',
      required: true,
      options: ['silent', 'error', 'warning', 'info', 'debug'],
      defaultValue: 'info',
      group: 'logs',
      labelKey: 'coreSettings.logLevel',
      helpKey: 'coreSettings.help.logLevel',
    ),
  ];

  static List<ProtocolField> fields({
    required List<String> logLevels,
    required String defaultLogLevel,
    String resolverHelp = 'coreSettings.help.resolvers',
    String logHelp = 'coreSettings.help.logLevel',
    bool singleResolver = false,
  }) => [
    for (final field in _baseFields)
      if (field.id == 'logLevel')
        ProtocolField.fromJson({
          ...field.toJson(),
          'options': logLevels,
          'defaultValue': defaultLogLevel,
          'helpKey': logHelp,
        })
      else if (field.id == 'resolvers')
        ProtocolField.fromJson({
          ...field.toJson(),
          'kind': singleResolver ? 'text' : 'lines',
          'helpKey': resolverHelp,
          'labelKey': singleResolver ? 'coreSettings.resolver' : field.labelKey,
        })
      else
        field,
  ];
  static Map<String, dynamic> document(String text) {
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic>)
      throw const ApiException('configuration_invalid', status: 422);
    return value;
  }

  static Map<String, String> read(
    List<ProtocolField> fields,
    String level,
    Map<String, String>? stored,
  ) => {
    for (final f in fields)
      f.id: stored?[f.id] ?? (f.id == 'logLevel' ? level : f.defaultValue),
  };
  static List<String> lines(String value) => value
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet()
      .toList();
  static bool domain(String value) =>
      value.length <= 253 &&
      value
          .split('.')
          .every(
            (s) => RegExp(
              r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$',
            ).hasMatch(s),
          ) &&
      InternetAddress.tryParse(value) == null;
  static bool cidr(String value) {
    final parts = value.split('/');
    if (parts.length != 2) return false;
    final ip = InternetAddress.tryParse(parts[0]),
        bits = int.tryParse(parts[1]);
    return ip != null &&
        bits != null &&
        bits >= 0 &&
        bits <= (ip.type == InternetAddressType.IPv4 ? 32 : 128);
  }

  static bool resolver(String value, List<String> schemes) {
    if (InternetAddress.tryParse(value) != null) return true;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !schemes.contains(uri.scheme) ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.host.isEmpty ||
        (!domain(uri.host) && InternetAddress.tryParse(uri.host) == null) ||
        (uri.hasPort && (uri.port < 1 || uri.port > 65535)) ||
        (uri.scheme != 'https' && uri.path.isNotEmpty))
      return false;
    return !RegExp(r'[\s,#]').hasMatch(value);
  }

  static Map<String, String> validate(
    List<ProtocolField> fields,
    Map<String, String> initial,
    Map<String, String> input, {
    List<String> schemes = const ['https', 'tls', 'udp', 'tcp'],
    int maxResolvers = 16,
  }) {
    if (input.keys.any((k) => !fields.any((f) => f.id == k)))
      throw const ApiException('settings_unsupported', status: 422);
    final values = {...initial, ...input};
    final errors = <String, String>{};
    for (final f in fields) {
      final error = f.validate(values[f.id] ?? '', values);
      if (error != null) errors[f.id] = error;
      if (f.id != 'resolvers' && (values[f.id] ?? '').isEmpty)
        errors[f.id] = 'required';
    }
    if (values['dnsMode'] == 'custom' &&
        (lines(values['resolvers']!).isEmpty ||
            lines(values['resolvers']!).length > maxResolvers ||
            lines(values['resolvers']!).any((s) => !resolver(s, schemes))))
      errors['resolvers'] = 'format_invalid';
    if (!errors.containsKey('accessRules')) {
      final rows = jsonDecode(values['accessRules']!) as List;
      if (rows.length > 64 ||
          rows.any(
            (row) =>
                !['domain', 'cidr'].contains(row['type']) ||
                !['allow', 'block'].contains(row['action']) ||
                (row['type'] == 'cidr'
                    ? !cidr(row['target'] as String)
                    : !domain(row['target'] as String)),
          ))
        errors['accessRules'] = 'format_invalid';
    }
    if (errors.isNotEmpty)
      throw ApiException('settings_unsupported', status: 422, fields: errors);
    values['resolvers'] = lines(values['resolvers']!).join('\n');
    return values;
  }

  static const privateNetworks = [
    '0.0.0.0/8',
    '10.0.0.0/8',
    '100.64.0.0/10',
    '127.0.0.0/8',
    '169.254.0.0/16',
    '172.16.0.0/12',
    '192.168.0.0/16',
    '224.0.0.0/4',
    '240.0.0.0/4',
    '::/128',
    '::1/128',
    '::ffff:0:0/96',
    'fc00::/7',
    'fe80::/10',
    'ff00::/8',
  ];
}
