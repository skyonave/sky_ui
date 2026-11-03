import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/state/panel_store.dart';

/// Constructor decisions and validation have no browser or component lifecycle.
class ConnectionDraft {
  ConnectionDraft({required this.store, required this.coreInstalled});
  final PanelStore store;
  final bool Function(String) coreInstalled;
  String? editingId, selectedCore, selectedProtocol, error;
  String connectionStep = 'protocol';
  Map<String, String> draft = {}, connectionErrors = {};
  final advancedGroups = <String>{};
  List<String> candidateEngines(String protocol) => [
    for (final id in productProtocol(protocol)?.engines ?? <String>[])
      if (store.supports(id, protocol)) id,
  ];

  List<String> get connectionSteps {
    final definition = selectedCore != null && selectedProtocol != null
        ? store.definition(selectedCore!, selectedProtocol!)
        : null;
    return [
      'protocol',
      if (selectedProtocol == null ||
          candidateEngines(selectedProtocol!).length > 1)
        'core',
      if (selectedCore != null && !coreInstalled(selectedCore!)) 'dependency',
      if (definition == null ||
          definition.fields.any((f) => f.group == 'transport'))
        'transport',
      if (definition == null ||
          definition.fields.any((f) => f.group == 'security'))
        'security',
      'parameters',
      'review',
    ];
  }

  void advanceConnection() {
    if (selectedCore == null || selectedProtocol == null) return;
    final definition = store.definition(selectedCore!, selectedProtocol!);
    connectionErrors = {
      for (final f
          in definition
              .activeFields(draft)
              .where(
                (f) => connectionStep == 'parameters'
                    ? !isStepChoice(f, definition)
                    : f.group == connectionStep && isStepChoice(f, definition),
              ))
        if (f.validate(draft[f.id] ?? '', draft) case final String e) f.id: e,
    };
    if (connectionStep == 'parameters') {
      if ((draft['name'] ?? '').trim().isEmpty)
        connectionErrors['name'] = 'required';
      final port = int.tryParse(draft['port'] ?? '');
      if (definition.usesPort && (port == null || port < 1 || port > 65535))
        connectionErrors['port'] = 'range_invalid';
    }
    if (connectionErrors.isNotEmpty) return;
    final steps = connectionSteps;
    var index = connectionStep == 'core' && !steps.contains('core')
        ? 1
        : steps.indexOf(connectionStep) + 1;
    while (index < steps.length - 1) {
      final fields = definition
          .activeFields(draft)
          .where((f) => f.group == steps[index] && isStepChoice(f, definition))
          .toList();
      if (fields.isNotEmpty &&
          !fields.every((f) => !f.advanced && f.options.length == 1))
        break;
      if (steps[index] == 'parameters') break;
      index++;
    }
    connectionStep = steps[index.clamp(0, steps.length - 1)];
    error = null;
  }

  bool isStepChoice(ProtocolField field, ProtocolDefinition definition) => {
    definition.clientFieldBindings['transport'],
    definition.clientFieldBindings['security'],
    if (definition.id == 'hysteria2') 'native.obfs',
    if (definition.id == 'hysteria2') 'obfs',
  }.contains(field.id);

  Map<String, String> blockedChoices(ProtocolField f) {
    if (selectedCore == null || selectedProtocol == null) return const {};
    final definition = store.definition(selectedCore!, selectedProtocol!);
    if (f.id != definition.clientFieldBindings['security']) return const {};
    return {
      for (final option in f.options)
        if (definition.exportRestrictions.any(
          (rule) => rule.matches(
            definition.clientValues(
              definition.defaults({...draft, f.id: option}),
            ),
          ),
        ))
          option: 'builder.profileUnavailable',
    };
  }

  void changeField(ProtocolField f, String value) {
    draft[f.id] = value;
    if (selectedCore != null && selectedProtocol != null)
      draft = store
          .definition(selectedCore!, selectedProtocol!)
          .defaults(draft);
    if (selectedCore != null && selectedProtocol != null) {
      final definition = store.definition(selectedCore!, selectedProtocol!);
      if (f.id == definition.clientFieldBindings['transport']) {
        final securityId = definition.clientFieldBindings['security'];
        final security = definition.fields
            .where((field) => field.id == securityId)
            .firstOrNull;
        if (security != null &&
            definition.exportRestrictions.any(
              (rule) => rule.matches(definition.clientValues(draft)),
            )) {
          for (final option in security.allowedOptions(draft)) {
            final candidate = definition.defaults({
              ...draft,
              security.id: option,
            });
            if (!definition.exportRestrictions.any(
              (rule) => rule.matches(definition.clientValues(candidate)),
            )) {
              draft = candidate;
              break;
            }
          }
        }
      }
    }
    connectionErrors.remove(f.id);
    error = null;
  }
}
