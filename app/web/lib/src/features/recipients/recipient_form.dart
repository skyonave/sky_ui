import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';

import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';
import '../../shared/state/panel_store.dart';

class RecipientForm extends StatelessComponent {
  const RecipientForm({
    required this.store,
    required this.draft,
    required this.grants,
    required this.busy,
    required this.onGrant,
    super.key,
  });
  final PanelStore store;
  final Map<String, String> draft;
  final Set<String> grants;
  final bool busy;
  final void Function(String, bool) onGrant;
  final t = const AppStrings();
  @override
  Component build(BuildContext context) => div([
    label([
      Component.text(t('users.name')),
      input<String>(
        value: draft['name'],
        disabled: busy,
        onInput: (v) => draft['name'] = v,
        attributes: {
          'autofocus': '',
          'maxlength': '80',
          'aria-required': 'true',
        },
      ),
    ]),
    h3([Component.text(t('users.access'))], classes: 'form-section-title'),
    div([
      for (final c in store.connections.where((c) => c.shareable))
        label([
          input<bool>(
            type: InputType.checkbox,
            checked: grants.contains(c.id),
            disabled: busy,
            onChange: (v) => onGrant(c.id, v),
          ),
          div([
            txt(c.name),
            txt(
              c.port == null
                  ? store.protocol(c.protocolId).name
                  : '${store.protocol(c.protocolId).name} · :${c.port}',
              classes: 'muted small',
            ),
          ]),
          if (!c.enabled) txt(t('status.disabled'), classes: 'muted small'),
        ], classes: 'grant-option'),
    ], classes: 'grant-list'),
  ]);
}
