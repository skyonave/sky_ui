class ProtocolField {
  const ProtocolField(
    this.id, {
    this.defaultValue = '',
    this.options = const [],
    this.required = false,
    this.secret = false,
    String? labelKey,
    String? helpKey,
  }) : _labelKey = labelKey,
       _helpKey = helpKey;
  final String id;
  final String defaultValue;
  final List<String> options;
  final bool required;
  final bool secret;
  final String? _labelKey;
  final String? _helpKey;
  String get labelKey => _labelKey ?? 'field.$id';
  String get helpKey => _helpKey ?? 'help.$id';
  Map<String, Object?> toJson() => {
    'id': id,
    'defaultValue': defaultValue,
    'options': options,
    'required': required,
    'secret': secret,
    'labelKey': labelKey,
    'helpKey': helpKey,
  };
  factory ProtocolField.fromJson(Map<String, dynamic> json) => ProtocolField(
    json['id'] as String,
    defaultValue: json['defaultValue'] as String,
    options: List<String>.from(json['options'] as List),
    required: json['required'] as bool,
    secret: json['secret'] as bool,
    labelKey: json['labelKey'] as String?,
    helpKey: json['helpKey'] as String?,
  );
}

class ProtocolDefinition {
  const ProtocolDefinition(
    this.id,
    this.name,
    this.fields, {
    this.usesPort = true,
  });
  final String id;
  final String name;
  final List<ProtocolField> fields;
  final bool usesPort;
  String get descriptionKey => 'protocol.$id';
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'usesPort': usesPort,
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
        usesPort: json['usesPort'] as bool,
      );
}
