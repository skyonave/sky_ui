import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/components/page_helpers.dart';
import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';
import '../../shared/protocols/catalog.dart';
import '../../shared/state/panel_store.dart';

class ConnectionsPage extends StatelessComponent {
  const ConnectionsPage({
    required this.store,
    required this.filter,
    required this.search,
    required this.canInspect,
    required this.canEdit,
    required this.dataBusy,
    required this.runtimeStatus,
    required this.coreInstalled,
    required this.newConnection,
    required this.toggleConnection,
    required this.confirmDelete,
    required this.onFilter,
    required this.onSearch,
    required this.onDiagnose,
    super.key,
  });
  final PanelStore store;
  final String filter;
  final String search;
  final bool canInspect;
  final bool canEdit;
  final bool dataBusy;
  final String runtimeStatus;
  final bool Function(String) coreInstalled;
  final void Function([Connection?]) newConnection;
  final void Function(Connection) toggleConnection;
  final void Function(String, String, String) confirmDelete;
  final void Function(String) onFilter;
  final void Function(String) onSearch;
  final void Function(Connection) onDiagnose;
  final t = const AppStrings();
  Component statistics() => div([
    stat(
      t('connections.count'),
      '${store.connections.length}',
      'connections',
      t('connections.configured'),
    ),
    stat(
      t('connections.activeCount'),
      '${store.activeConnections}',
      'bolt',
      'mihomo',
    ),
    stat(
      t('users.count'),
      '${store.activeRecipients}',
      'users',
      t('users.active'),
    ),
  ], classes: 'stats-grid');

  @override
  Component build(BuildContext context) => div([
    heading(
      'connections',
      trailing: action(
        t('connections.add'),
        newConnection,
        disabled: !canInspect,
        glyph: 'plus',
        classes: 'button primary',
      ),
    ),
    statistics(),
    div([
      div([
        div([
          for (final f in ['all', 'active', 'disabled'])
            button(
              [
                Component.text(
                  t(f == 'all' ? 'connections.all' : 'connections.$f'),
                ),
                if (f == 'all')
                  txt('${store.connections.length}', classes: 'tab-count'),
              ],
              classes: 'tab ${filter == f ? 'active' : ''}',
              onClick: () => onFilter(f),
              type: ButtonType.button,
            ),
        ], classes: 'tabs'),
        div([
          icon('search'),
          input<String>(
            value: search,
            onInput: (v) => onSearch(v),
            attributes: {
              'placeholder': t('connections.search'),
              'aria-label': t('connections.search'),
            },
          ),
        ], classes: 'search'),
      ], classes: 'table-toolbar'),
      connectionTable(
        store.connections
            .where(
              (c) =>
                  (filter == 'all' || c.enabled == (filter == 'active')) &&
                  '${c.name} ${c.protocolId} ${c.port}'.toLowerCase().contains(
                    search.toLowerCase(),
                  ),
            )
            .toList(),
      ),
      div([
        span([
          span([], classes: 'status-dot'),
          Component.text(runtimeStatus),
        ], classes: 'table-summary'),
        txt(store.serverName, classes: 'mono muted'),
      ], classes: 'table-footer'),
    ], classes: 'panel connection-panel'),
  ]);

  Component connectionTable(List<Connection> list) {
    if (list.isEmpty)
      return emptyState(
        'connections',
        t('connections.empty'),
        t('connections.emptyHint'),
      );
    return div([
      el('table', [
        el('colgroup', [
          for (final width in [28, 16, 14, 20, 10, 12])
            el('col', [], attributes: {'style': 'width: $width%'}),
        ]),
        el('thead', [
          el('tr', [
            for (final k in [
              'name',
              'protocol',
              'transport',
              'status',
              'enabled',
            ])
              el('th', [Component.text(t('table.$k'))]),
            el('th', [
              span([Component.text(t('table.actions'))], classes: 'sr-only'),
            ]),
          ]),
        ]),
        el('tbody', [
          for (final c in list)
            el('tr', [
              el('td', [
                div([
                  div([
                    icon('connections'),
                  ], classes: 'connection-icon ${c.enabled ? '' : 'dim'}'),
                  div([
                    button(
                      [Component.text(c.name)],
                      classes: 'name-button',
                      onClick: () => newConnection(c),
                      type: ButtonType.button,
                    ),
                    txt(
                      c.port == null
                          ? '—'
                          : '${store.address}:${c.assignedPorts.firstOrNull ?? c.port}${c.assignedPorts.length > 1 ? ' (+${c.assignedPorts.length - 1})' : ''}',
                      classes: 'endpoint',
                    ),
                  ]),
                ], classes: 'connection-name'),
              ]),
              el('td', [
                txt(
                  store.protocol(c.protocolId).name,
                  classes: 'protocol-tag ${c.protocolId}',
                ),
                txt(coreName(c.coreId), classes: 'transport-note'),
              ]),
              el('td', [
                txt(
                  c.settings['transport'] ??
                      (['hysteria2', 'tuic'].contains(c.protocolId)
                          ? 'QUIC'
                          : c.settings['network'] ?? 'TCP'),
                  classes: 'mono table-value',
                ),
                if (c.settings['security'] != null)
                  txt(c.settings['security']!, classes: 'transport-note'),
              ]),
              el('td', [
                pill(
                  t(
                    dataBusy
                        ? 'data.applying'
                        : !coreInstalled(c.coreId)
                        ? 'core.missingStatus'
                        : !c.enabled
                        ? 'status.disabled'
                        : c.shareable && store.recipientsFor(c.id).isEmpty
                        ? 'status.unassigned'
                        : !store.deliveryReady
                        ? 'status.stopped'
                        : 'status.active',
                  ),
                  positive:
                      !dataBusy &&
                      c.enabled &&
                      coreInstalled(c.coreId) &&
                      store.deliveryReady &&
                      (!c.shareable || store.recipientsFor(c.id).isNotEmpty),
                ),
              ]),
              el('td', [
                enabledCheckbox(
                  c.enabled,
                  '${t(c.enabled ? 'common.disable' : 'common.enable')}: ${c.name}',
                  () => toggleConnection(c),
                  disabled: !canEdit,
                ),
              ]),
              el('td', [
                div([
                  iconButton(
                    'activity',
                    '${t('diagnostics.action')}: ${c.name}',
                    () => onDiagnose(c),
                    disabled: !canInspect,
                  ),
                  iconButton(
                    'edit',
                    '${t('common.edit')}: ${c.name}',
                    () => newConnection(c),
                  ),
                  iconButton(
                    'trash',
                    '${t('common.delete')}: ${c.name}',
                    () => confirmDelete('connection', c.id, c.name),
                  ),
                ], classes: 'row-actions'),
              ]),
            ], key: ValueKey(c.id)),
        ]),
      ]),
    ], classes: 'table-scroll connections-table');
  }
}
