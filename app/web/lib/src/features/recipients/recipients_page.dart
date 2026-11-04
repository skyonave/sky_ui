import 'dart:async';

import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/components/page_helpers.dart';
import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';
import '../../shared/state/panel_store.dart';

class RecipientsPage extends StatelessComponent {
  const RecipientsPage({
    required this.store,
    required this.presence,
    required this.canInspect,
    required this.canEdit,
    required this.editRecipient,
    required this.toggleRecipient,
    required this.openSharing,
    required this.confirmDelete,
    super.key,
  });
  final PanelStore store;
  final Map<String, RecipientPresence> presence;
  final bool canInspect;
  final bool canEdit;
  final void Function([Recipient?]) editRecipient;
  final void Function(Recipient) toggleRecipient;
  final Future<void> Function(Recipient) openSharing;
  final void Function(String, String, String) confirmDelete;
  final t = const AppStrings();
  @override
  Component build(BuildContext context) => div([
    heading(
      'users',
      trailing: action(
        t('users.add'),
        editRecipient,
        disabled: !canInspect,
        glyph: 'plus',
        classes: 'button primary',
      ),
    ),
    if (store.recipients.isEmpty)
      emptyState('users', t('users.none'))
    else
      div([
        el(
          'table',
          [
            el('colgroup', [
              for (final width in [24, 30, 15, 11, 20])
                el('col', [], attributes: {'style': 'width: $width%'}),
            ]),
            el('thead', [
              el('tr', [
                for (final key in [
                  'recipient',
                  'access',
                  'status',
                  'enabled',
                  'actions',
                ])
                  el('th', [Component.text(t('table.$key'))]),
              ]),
            ]),
            el('tbody', [
              for (final user in store.recipients)
                el('tr', [
                  el('td', [
                    div([
                      div([
                        Component.text(
                          String.fromCharCode(user.name.runes.first),
                        ),
                      ], classes: 'user-avatar'),
                      button(
                        [Component.text(user.name)],
                        classes: 'name-button',
                        type: ButtonType.button,
                        onClick: () => editRecipient(user),
                      ),
                    ], classes: 'user-name'),
                  ]),
                  el('td', [
                    div([
                      for (final c in store.connections.where(
                        (c) => user.connectionIds.contains(c.id),
                      ))
                        span(
                          [
                            span(
                              [],
                              classes:
                                  'status-dot ${c.enabled && user.enabled ? '' : 'off'}',
                            ),
                            span([
                              Component.text(c.name),
                            ], classes: 'access-name'),
                          ],
                          classes: 'access-tag',
                          attributes: {
                            'title': user.connectionPorts[c.id] == null
                                ? c.name
                                : '${c.name} · :${user.connectionPorts[c.id]}',
                          },
                        ),
                      if (user.connectionIds.isEmpty)
                        txt('—', classes: 'muted'),
                    ], classes: 'access-list'),
                  ]),
                  el('td', [_presence(user)]),
                  el('td', [
                    enabledCheckbox(
                      user.enabled,
                      '${t(user.enabled ? 'common.disable' : 'common.enable')}: ${user.name}',
                      () => toggleRecipient(user),
                      disabled: !canEdit,
                    ),
                  ]),
                  el('td', [
                    div([
                      action(
                        t('users.subscription'),
                        () {
                          unawaited(openSharing(user));
                        },
                        glyph: 'link',
                        classes: 'button compact',
                        disabled: !user.enabled,
                      ),
                      iconButton(
                        'edit',
                        '${t('common.edit')}: ${user.name}',
                        () => editRecipient(user),
                      ),
                      iconButton(
                        'trash',
                        '${t('common.delete')}: ${user.name}',
                        () => confirmDelete('recipient', user.id, user.name),
                      ),
                    ], classes: 'row-actions'),
                  ]),
                ], key: ValueKey(user.id)),
            ]),
          ],
          attributes: {'aria-label': t('users.title')},
        ),
      ], classes: 'table-scroll users-table'),
  ]);

  Component _presence(Recipient user) {
    final value = user.enabled
        ? presence[user.id] ?? RecipientPresence.unavailable
        : RecipientPresence.offline;
    return span(
      [Component.text(t('users.presence.${value.name}'))],
      classes: 'recipient-presence ${value.name}',
      attributes: {'title': t('users.presence.help.${value.name}')},
    );
  }
}
