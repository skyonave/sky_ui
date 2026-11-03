import 'dart:convert';

/// Core-independent form conditions; a missing dependency never matches.
bool matchesConditions(
  Map<String, List<String>> conditions,
  Map<String, String> values,
) => conditions.entries.every(
  (entry) => entry.value.contains(values[entry.key]),
);

class ProtocolField {
  const ProtocolField(
    this.id, {
    this.defaultValue = '',
    this.options = const [],
    this.required = false,
    this.secret = false,
    String? labelKey,
    String? helpKey,
    this.kind = 'text',
    this.group = 'parameters',
    this.advanced = false,
    this.when = const {},
    this.optionWhen = const {},
    this.optionWhenAny = const {},
    this.minimum,
    this.maximum,
    this.maxLength = 512,
    this.pattern,
    this.children = const [],
    this.derivedFrom,
    this.deriveWhen = const {},
    this.deriveValueMap = const {},
    this.itemKind = 'text',
    this.rowKeyField,
    this.generator,
  }) : _labelKey = labelKey,
       _helpKey = helpKey;
  final String id, defaultValue, kind, group;
  final String itemKind;
  final String? rowKeyField;
  final String? generator;
  final List<String> options;
  final bool required, secret, advanced;
  final String? _labelKey, _helpKey, pattern;
  final int? minimum, maximum;
  final int maxLength;
  final Map<String, List<String>> when;
  final Map<String, Map<String, List<String>>> optionWhen;
  final Map<String, List<Map<String, List<String>>>> optionWhenAny;
  final List<ProtocolField> children;
  final String? derivedFrom;
  final Map<String, List<String>> deriveWhen;
  final Map<String, String> deriveValueMap;
  String derivedValue(Map<String, String> values) =>
      deriveValueMap[values[derivedFrom]] ?? values[derivedFrom] ?? '';
  bool derived(Map<String, String> values) =>
      derivedFrom != null && matchesConditions(deriveWhen, values);
  String get labelKey => _labelKey ?? 'field.$id';
  String get helpKey => _helpKey ?? 'help.$id';
  bool visible(Map<String, String> values) => matchesConditions(when, values);
  List<String> allowedOptions(Map<String, String> values) => options
      .where(
        (option) =>
            matchesConditions(optionWhen[option] ?? const {}, values) &&
            (optionWhenAny[option]?.any(
                  (condition) => matchesConditions(condition, values),
                ) ??
                true),
      )
      .toList();
  String initialValue(Map<String, String> values) {
    final allowed = allowedOptions(values);
    return options.isEmpty || allowed.contains(defaultValue)
        ? defaultValue
        : (allowed.firstOrNull ?? '');
  }

  String? validate(String value, Map<String, String> values) {
    if (!visible(values)) return null;
    if (required &&
        value.trim().isEmpty &&
        !(secret && values['_stored:$id'] == 'true'))
      return 'required';
    if (value.isEmpty) return null;
    if (value.length > maxLength) return 'too_long';
    if (options.isNotEmpty && !allowedOptions(values).contains(value))
      return 'choice_invalid';
    if (kind == 'integer') {
      final parsed = int.tryParse(value);
      if (parsed == null) return 'integer_invalid';
      if (minimum != null && parsed < minimum! ||
          maximum != null && parsed > maximum!)
        return 'range_invalid';
    }
    if (kind == 'boolean' && value != 'true' && value != 'false')
      return 'boolean_invalid';
    if (kind == 'lines' && itemKind == 'integer') {
      for (final line
          in value.split('\n').where((line) => line.trim().isNotEmpty)) {
        final parsed = int.tryParse(line.trim());
        if (parsed == null) return 'integer_invalid';
        if (minimum != null && parsed < minimum! ||
            maximum != null && parsed > maximum!)
          return 'range_invalid';
      }
    }
    if (pattern != null && !RegExp(pattern!).hasMatch(value))
      return 'format_invalid';
    if (kind == 'rows') {
      try {
        final rows = jsonDecode(value);
        if (rows is! List || rows.length > 256) return 'rows_invalid';
        final keys = <String>{};
        for (final row in rows) {
          if (row is! Map ||
              row.values.any((v) => v is! String) ||
              row.keys.any((key) => !children.any((f) => f.id == key)))
            return 'rows_invalid';
          if (rowKeyField != null &&
              ((row[rowKeyField] as String? ?? '').isEmpty ||
                  !keys.add(row[rowKeyField] as String)))
            return 'rows_invalid';
          final data = <String, String>{
            for (final e in row.entries) e.key as String: e.value.toString(),
          };
          if (children.any(
            (f) => f.validate(data[f.id] ?? f.initialValue(data), data) != null,
          ))
            return 'rows_invalid';
        }
      } on Object {
        return 'rows_invalid';
      }
    }
    return null;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'defaultValue': defaultValue,
    'options': options,
    'required': required,
    'secret': secret,
    'labelKey': labelKey,
    'helpKey': helpKey,
    'kind': kind,
    'group': group,
    'advanced': advanced,
    'when': when,
    'optionWhen': optionWhen,
    'optionWhenAny': optionWhenAny,
    'minimum': minimum,
    'maximum': maximum,
    'maxLength': maxLength,
    'pattern': pattern,
    'children': children.map((f) => f.toJson()).toList(),
    'derivedFrom': derivedFrom,
    'deriveWhen': deriveWhen,
    'deriveValueMap': deriveValueMap,
    'itemKind': itemKind,
    'rowKeyField': rowKeyField,
    'generator': generator,
  };
  factory ProtocolField.fromJson(Map<String, dynamic> json) => ProtocolField(
    json['id'] as String,
    defaultValue: json['defaultValue'] as String? ?? '',
    options: List<String>.from(json['options'] as List? ?? []),
    required: json['required'] == true,
    secret: json['secret'] == true,
    labelKey: json['labelKey'] as String?,
    helpKey: json['helpKey'] as String?,
    kind: json['kind'] as String? ?? 'text',
    group: json['group'] as String? ?? 'parameters',
    advanced: json['advanced'] == true,
    when: _conditions(json['when']),
    optionWhen: (json['optionWhen'] as Map? ?? {}).map(
      (k, v) => MapEntry(k as String, _conditions(v)),
    ),
    optionWhenAny: (json['optionWhenAny'] as Map? ?? {}).map(
      (k, v) => MapEntry(k as String, (v as List).map(_conditions).toList()),
    ),
    minimum: json['minimum'] as int?,
    maximum: json['maximum'] as int?,
    maxLength: json['maxLength'] as int? ?? 512,
    pattern: json['pattern'] as String?,
    children: (json['children'] as List? ?? [])
        .map((v) => ProtocolField.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList(),
    derivedFrom: json['derivedFrom'] as String?,
    deriveWhen: _conditions(json['deriveWhen']),
    deriveValueMap: Map<String, String>.from(
      json['deriveValueMap'] as Map? ?? {},
    ),
    itemKind: json['itemKind'] as String? ?? 'text',
    rowKeyField: json['rowKeyField'] as String?,
    generator: json['generator'] as String?,
  );
}

Map<String, List<String>> _conditions(Object? value) =>
    (value as Map? ?? {}).map(
      (key, value) => MapEntry(key as String, List<String>.from(value as List)),
    );

class ProtocolDefinition {
  const ProtocolDefinition(
    this.id,
    this.name,
    this.fields, {
    this.usesPort = true,
    this.available = true,
    this.unavailableKey,
    this.category = 'proxy',
    this.shareable = true,
    this.isolatedBindings = false,
    this.context = const {},
    this.clientFieldBindings = const {},
    this.exportRestrictions = const [],
    this.deliveryHintKey,
  });
  final String id, name, category;
  final List<ProtocolField> fields;
  final bool usesPort, available;
  final bool shareable, isolatedBindings;
  final Map<String, String> context;
  final Map<String, String> clientFieldBindings;
  final List<ClientExportRestriction> exportRestrictions;
  final String? deliveryHintKey;
  Map<String, String> clientValues(Map<String, String> form) => {
    for (final binding in clientFieldBindings.entries)
      binding.key: form[binding.value] ?? '',
  };
  ProtocolDefinition withExportRestrictions(
    List<ClientExportRestriction> rules,
  ) => ProtocolDefinition(
    id,
    name,
    fields,
    usesPort: usesPort,
    available: available,
    unavailableKey: unavailableKey,
    category: category,
    shareable: shareable,
    isolatedBindings: isolatedBindings,
    context: context,
    clientFieldBindings: clientFieldBindings,
    exportRestrictions: rules.where((r) => r.protocolIds.contains(id)).toList(),
    deliveryHintKey: deliveryHintKey,
  );
  final String? unavailableKey;
  String get descriptionKey => 'protocol.$id';
  String get detailsKey => 'protocol.$id.details';
  List<ProtocolField> activeFields(Map<String, String> values) =>
      fields.where((f) => f.visible(values)).toList();

  /// Stabilize dependent choices after a parent selection without losing hidden drafts.
  Map<String, String> defaults([Map<String, String> previous = const {}]) {
    final values = <String, String>{
      for (final f in fields) f.id: previous[f.id] ?? f.defaultValue,
      ...previous,
      ...context,
    };
    for (var pass = 0; pass < fields.length + 1; pass++) {
      var changed = false;
      for (final f in fields) {
        if (f.derived(values) && values[f.id] != f.derivedValue(values)) {
          values[f.id] = f.derivedValue(values);
          changed = true;
        }
        if (!f.visible(values) || f.options.isEmpty) continue;
        if (!f.allowedOptions(values).contains(values[f.id])) {
          final next = f.initialValue(values);
          if (values[f.id] != next) {
            values[f.id] = next;
            changed = true;
          }
        }
      }
      if (!changed) break;
    }
    return values;
  }

  Map<String, String> validateFields(Map<String, String> values) => {
    for (final f in activeFields(values))
      if (f.validate(values[f.id] ?? f.initialValue(values), values)
          case final String error)
        f.id: error,
  };
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'usesPort': usesPort,
    'available': available,
    'unavailableKey': unavailableKey,
    'category': category,
    'shareable': shareable,
    'isolatedBindings': isolatedBindings,
    'context': context,
    'clientFieldBindings': clientFieldBindings,
    'exportRestrictions': exportRestrictions.map((r) => r.toJson()).toList(),
    'deliveryHintKey': deliveryHintKey,
    'fields': fields.map((v) => v.toJson()).toList(),
  };
  factory ProtocolDefinition.fromJson(Map<String, dynamic> json) =>
      ProtocolDefinition(
        json['id'] as String,
        json['name'] as String,
        (json['fields'] as List)
            .map(
              (v) =>
                  ProtocolField.fromJson(Map<String, dynamic>.from(v as Map)),
            )
            .toList(),
        usesPort: json['usesPort'] as bool? ?? true,
        available: json['available'] as bool? ?? true,
        unavailableKey: json['unavailableKey'] as String?,
        category: json['category'] as String? ?? 'proxy',
        shareable: json['shareable'] as bool? ?? true,
        isolatedBindings: json['isolatedBindings'] as bool? ?? false,
        context: Map<String, String>.from(json['context'] as Map? ?? {}),
        clientFieldBindings: Map<String, String>.from(
          json['clientFieldBindings'] as Map? ?? {},
        ),
        exportRestrictions: (json['exportRestrictions'] as List? ?? [])
            .map(
              (r) => ClientExportRestriction.fromJson(
                Map<String, dynamic>.from(r as Map),
              ),
            )
            .toList(),
        deliveryHintKey: json['deliveryHintKey'] as String?,
      );
}

/// Exporter-owned compatibility policy over portable client features.
class ClientExportRestriction {
  const ClientExportRestriction({
    required this.protocolIds,
    required this.format,
    required this.when,
    this.reasonKey = 'builder.profileUnavailable',
  });
  final List<String> protocolIds;
  final String format, reasonKey;
  final Map<String, List<String>> when;
  bool matches(Map<String, String> features) =>
      matchesConditions(when, features);
  Map<String, Object> toJson() => {
    'protocolIds': protocolIds,
    'format': format,
    'when': when,
    'reasonKey': reasonKey,
  };
  factory ClientExportRestriction.fromJson(Map<String, dynamic> json) =>
      ClientExportRestriction(
        protocolIds: List<String>.from(json['protocolIds'] as List),
        format: json['format'] as String,
        when: _conditions(json['when']),
        reasonKey: json['reasonKey'] as String? ?? 'builder.profileUnavailable',
      );
}
