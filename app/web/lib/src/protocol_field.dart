import 'dart:convert';
import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'field_help.dart';
import 'i18n.dart';
import 'ui.dart';

/// Renders typed schema fields, including repeatable rows, without core-specific branches.
class ProtocolFieldView extends StatelessComponent {
  const ProtocolFieldView({
    required this.field,
    required this.values,
    required this.onChanged,
    this.error,
    this.busy = false,
    this.prefix = '',
    this.configured = false,
    this.blockedOptions = const {},
    this.guideScope = '',
    super.key,
  });
  final ProtocolField field;
  final Map<String, String> values;
  final void Function(String, bool) onChanged;
  final String? error;
  final bool busy, configured;
  final Map<String, String> blockedOptions;
  final String prefix;
  final String guideScope;
  static const t = AppStrings();
  String choice(String value) {
    if (value.isEmpty) return t('builder.default');
    final key = 'builder.choice.${field.id}.$value', label = t(key);
    return label == key ? value : label;
  }

  @override
  Component build(BuildContext context) {
    final value = values[field.id] ?? field.initialValue(values),
        id = 'field-$prefix${field.id}'.replaceAll(
          RegExp(r'[^A-Za-z0-9_-]'),
          '_',
        );
    final usableOptions = field
        .allowedOptions(values)
        .where((option) => !blockedOptions.containsKey(option))
        .toList();
    final recommended = usableOptions.contains(field.defaultValue)
        ? field.defaultValue
        : usableOptions.firstOrNull;
    final scopedGuideKey = 'builder.guide.$guideScope.$value';
    final guideKey = t(scopedGuideKey) != scopedGuideKey
            ? scopedGuideKey
            : 'builder.guide.$value',
        guide = t(guideKey);
    final specificHint = 'builder.inline.${field.id}.$value',
        baseHint = 'builder.inline.${field.id}';
    final hint = t(specificHint) != specificHint
        ? t(specificHint)
        : t(baseHint) != baseHint
        ? t(baseHint)
        : null;
    return div(
      [
        div([
          el(
            'label',
            [
              Component.text(t(field.labelKey)),
              if (field.required) txt(' *', classes: 'muted'),
            ],
            attributes: {'for': id},
          ),
          FieldHelp(
            id: 'help-$id',
            label: t(field.labelKey),
            description: t(field.helpKey),
            buttonLabel: t('common.help', {'name': t(field.labelKey)}),
            key: ValueKey('help:$prefix:${field.id}'),
          ),
        ], classes: 'field-label'),
        if (field.kind == 'choice')
          div([
            for (final option in field.options)
              button(
                [
                  span([
                    txt(choice(option)),
                    if (field.options.length > 1 && option == recommended)
                      txt(
                        t('builder.recommended'),
                        classes: 'recommended-chip',
                      ),
                  ], classes: 'builder-choice-heading'),
                  if (blockedOptions.containsKey(option))
                    txt(
                      t('builder.unavailableClash'),
                      classes: 'availability-chip unavailable',
                    ),
                  if (t('builder.choice.${field.id}.$option.help') !=
                      'builder.choice.${field.id}.$option.help')
                    p([
                      Component.text(
                        t('builder.choice.${field.id}.$option.help'),
                      ),
                    ], classes: 'muted small'),
                ],
                type: ButtonType.button,
                classes: 'builder-choice ${value == option ? 'selected' : ''}',
                disabled:
                    busy ||
                    !field.allowedOptions(values).contains(option) ||
                    blockedOptions.containsKey(option),
                onClick: () => onChanged(option, true),
              ),
          ], classes: 'builder-choice-grid'),
        if (field.kind == 'choice' &&
            field.id == 'transport' &&
            guide != guideKey)
          div([
            txt(t('builder.guideTitle'), classes: 'transport-guide-title'),
            p([Component.text(guide)]),
          ], classes: 'transport-guide'),
        if (field.kind == 'rows')
          rows(value, id)
        else if (field.kind == 'boolean')
          input<bool>(
            id: id,
            type: InputType.checkbox,
            checked: value == 'true',
            disabled: busy,
            onChange: (v) => onChanged('$v', true),
          )
        else if (field.kind == 'multiline' || field.kind == 'lines')
          textarea(
            [Component.text(value)],
            id: id,
            rows: field.kind == 'lines' ? 3 : 6,
            disabled: busy,
            onInput: (v) => onChanged(v, false),
            attributes: {
              'maxlength': '${field.maxLength}',
              'autocomplete': 'off',
              if (configured) 'placeholder': t('builder.secretStored'),
            },
          )
        else if (field.kind != 'choice' && field.options.isNotEmpty)
          select(
            [
              for (final option in field.options)
                el(
                  'option',
                  [Component.text(choice(option))],
                  attributes: {
                    'value': option,
                    if (value == option) 'selected': '',
                    if (!field.allowedOptions(values).contains(option))
                      'disabled': '',
                  },
                ),
            ],
            id: id,
            value: value,
            disabled: busy,
            onChange: (v) => onChanged(v.first, true),
          )
        else if (field.kind == 'integer' && !field.secret)
          input<num>(
            id: id,
            value: value,
            disabled: busy,
            type: InputType.number,
            onInput: (v) => onChanged(v.isFinite ? '$v' : '', false),
            attributes: {
              if (field.minimum != null) 'min': '${field.minimum}',
              if (field.maximum != null) 'max': '${field.maximum}',
              if (field.required) 'aria-required': 'true',
              if (error != null) 'aria-invalid': 'true',
              if (field.derived(values)) 'readonly': '',
              'autocomplete': 'off',
            },
          )
        else if (field.kind != 'choice')
          input<String>(
            id: id,
            value: value,
            disabled: busy,
            type: field.secret ? InputType.password : InputType.text,
            onInput: (v) => onChanged(v, false),
            attributes: {
              'maxlength': '${field.maxLength}',
              if (field.minimum != null) 'min': '${field.minimum}',
              if (field.maximum != null) 'max': '${field.maximum}',
              if (field.required) 'aria-required': 'true',
              if (error != null) 'aria-invalid': 'true',
              if (configured) 'placeholder': t('builder.secretStored'),
              'autocomplete': 'off',
              if (field.derived(values)) 'readonly': '',
            },
          ),
        if (hint != null) p([Component.text(hint)], classes: 'field-hint'),
        if (error != null)
          txt(t('builder.error.$error'), classes: 'field-error'),
      ],
      classes:
          'field ${field.kind == 'choice' || field.kind == 'rows' || field.kind == 'multiline' ? 'full-field' : ''}',
    );
  }

  Component rows(String value, String id) {
    final entries = <Map<String, String>>[];
    try {
      for (final entry in jsonDecode(value.isEmpty ? '[]' : value) as List)
        entries.add(Map<String, String>.from(entry as Map));
    } on Object {}
    return div([
      for (var index = 0; index < entries.length; index++)
        div([
          div([
            for (final child in field.children)
              ProtocolFieldView(
                field: child,
                values: entries[index],
                busy: busy,
                prefix: '$id-$index-',
                onChanged: (v, rebuild) {
                  entries[index][child.id] = v;
                  onChanged(jsonEncode(entries), rebuild);
                },
                key: ValueKey('$id-$index-${child.id}'),
              ),
          ], classes: 'form-grid'),
          iconButton('trash', t('common.delete'), () {
            entries.removeAt(index);
            onChanged(jsonEncode(entries), true);
          }, disabled: busy),
        ], classes: 'builder-row'),
      action(
        t('builder.addRow'),
        () {
          entries.add({
            for (final child in field.children) child.id: child.defaultValue,
          });
          onChanged(jsonEncode(entries), true);
        },
        glyph: 'plus',
        disabled: busy || entries.length >= 256,
      ),
    ], classes: 'builder-rows');
  }
}
