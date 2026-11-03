import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/components/page_helpers.dart';
import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';

class SessionList extends StatelessComponent {
  const SessionList({
    required this.ownerSessions,
    required this.ownerBusy,
    required this.onRevoke,
    super.key,
  });
  final List<OwnerSession> ownerSessions;
  final bool ownerBusy;
  final void Function(String) onRevoke;
  final t = const AppStrings();
  @override
  Component build(BuildContext context) => div([
    if (ownerSessions.isEmpty)
      p([Component.text(t('runtime.loading'))], classes: 'muted'),
    if (ownerSessions.isNotEmpty)
      el('table', [
        el('thead', [
          el('tr', [
            for (final key in [
              'admin.device',
              'admin.ip',
              'admin.lastSeen',
              'admin.actions',
            ])
              el('th', [Component.text(t(key))]),
          ]),
        ]),
        el('tbody', [
          for (final session in ownerSessions)
            el('tr', [
              el('td', [
                txt(sessionDevice(session.agent)),
                if (session.current)
                  txt(t('admin.currentSession'), classes: 'muted small'),
              ]),
              el('td', [txt(session.ip, classes: 'mono')]),
              el('td', [txt(sessionTime(session.lastSeen), classes: 'mono')]),
              el('td', [
                iconButton('logout', t('admin.revoke'), () {
                  onRevoke(session.id);
                }, disabled: ownerBusy),
              ]),
            ]),
        ]),
      ], classes: 'session-table'),
  ], classes: 'session-container');
}
