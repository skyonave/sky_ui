import 'protocols.dart';

/// An instance-scoped form, independent of any engine's native document.
class CoreSettings {
  const CoreSettings({
    required this.instanceId,
    required this.coreId,
    required this.revision,
    required this.fields,
    required this.values,
  });
  final String instanceId, coreId;
  final int revision;
  final List<ProtocolField> fields;
  final Map<String, String> values;
  Map<String, Object?> toJson() => {
    'instanceId': instanceId,
    'coreId': coreId,
    'revision': revision,
    'fields': fields.map((f) => f.toJson()).toList(),
    'values': values,
  };
  factory CoreSettings.fromJson(Map<String, dynamic> json) => CoreSettings(
    instanceId: json['instanceId'] as String,
    coreId: json['coreId'] as String,
    revision: json['revision'] as int,
    fields: (json['fields'] as List)
        .map((f) => ProtocolField.fromJson(Map<String, dynamic>.from(f as Map)))
        .toList(),
    values: Map<String, String>.from(json['values'] as Map),
  );
}
