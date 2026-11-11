import 'dart:async';

import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';

import '../shared/components/primitives.dart';
import '../shared/localization/strings.dart';

class AppSidebar extends StatelessComponent {
  const AppSidebar({
    required this.page,
    required this.username,
    required this.busy,
    required this.inert,
    required this.connectionCount,
    required this.panelUpdateCard,
    required this.navigate,
    required this.onSignOut,
    super.key,
  });
  final String page;
  final String? username;
  final bool busy;
  final bool inert;
  final int connectionCount;
  final Component Function() panelUpdateCard;
  final void Function(String) navigate;
  final Future<void> Function() onSignOut;
  final t = const AppStrings();
  @override
  Component build(BuildContext context) => el(
    'aside',
    [
      div([
        div([
          el(
            'svg',
            [
              el('path', [], attributes: {'d': 'M5 18 12 5l7 13M9 18l3-6 3 6'}),
            ],
            attributes: {
              'viewBox': '0 0 24 24',
              'fill': 'none',
              'stroke': 'currentColor',
              'stroke-width': '2',
              'stroke-linecap': 'round',
              'stroke-linejoin': 'round',
              'aria-hidden': 'true',
            },
          ),
        ], classes: 'brand-mark'),
        div([
          el('strong', [Component.text(t('app.name'))]),
        ], classes: 'brand-text'),
      ], classes: 'brand'),
      div([
        txt(t('nav.workspace'), classes: 'nav-label'),
        for (final key in ['overview', 'connections', 'users']) navItem(key),
        txt(t('nav.system'), classes: 'nav-label second-label'),
        for (final key in ['servers', 'routing', 'core', 'logs', 'settings'])
          navItem(key),
      ], classes: 'navigation'),
      div([
        panelUpdateCard(),
        div([
          txt(username ?? '', classes: 'owner-name'),
          iconButton(
            'logout',
            t('auth.signOut'),
            () => unawaited(onSignOut()),
            disabled: busy,
          ),
        ], classes: 'owner'),
      ], classes: 'sidebar-bottom'),
    ],
    classes: 'sidebar',
    attributes: {if (inert) 'inert': ''},
  );

  Component navItem(String key) => button(
    [
      icon(switch (key) {
        'overview' => 'grid',
        'servers' => 'server',
        _ => key,
      }),
      txt(t('nav.$key')),
      if (key == 'connections') txt('$connectionCount', classes: 'nav-count'),
    ],
    classes: 'nav-item ${page == key ? 'selected' : ''}',
    type: ButtonType.button,
    onClick: () => navigate(key),
    attributes: {
      'aria-label': t('nav.$key'),
      'title': t('nav.$key'),
      if (page == key) 'aria-current': 'page',
    },
  );
}
