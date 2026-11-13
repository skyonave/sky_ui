import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:sky_ui_web/src/features/connections/connection_draft.dart';
import 'package:sky_ui_web/src/shared/state/panel_store.dart';

void require(bool value, String message) {
  if (!value) throw StateError(message);
}

void main() {
  const transport = ProtocolField(
    'transport',
    kind: 'choice',
    group: 'transport',
    defaultValue: 'TCP',
    options: ['TCP', 'WebSocket'],
  );
  const security = ProtocolField(
    'security',
    kind: 'choice',
    group: 'security',
    defaultValue: 'REALITY',
    options: ['REALITY', 'TLS'],
  );
  const vless = ProtocolDefinition(
    'vless',
    'VLESS',
    [transport, security],
    clientFieldBindings: {'transport': 'transport', 'security': 'security'},
    exportRestrictions: [
      ClientExportRestriction(
        protocolIds: ['vless'],
        format: 'clash',
        when: {
          'transport': ['WebSocket'],
          'security': ['REALITY'],
        },
      ),
    ],
  );
  final store = PanelStore()
    ..protocols = {
      'xray': [vless],
      'mihomo': [vless],
    };
  var installed = false;
  final draft = ConnectionDraft(store: store, coreInstalled: (_) => installed)
    ..selectedProtocol = 'vless'
    ..selectedCore = 'xray'
    ..draft = {
      'name': 'Personal',
      'port': '35001',
      'transport': 'TCP',
      'security': 'REALITY',
    };
  require(
    draft.connectionSteps.contains('core'),
    'Multiple engines require a choice.',
  );
  require(
    draft.connectionSteps.contains('dependency'),
    'Missing engine requires installation.',
  );
  installed = true;
  require(
    !draft.connectionSteps.contains('dependency'),
    'Installed engine must not require installation.',
  );
  draft.changeField(transport, 'WebSocket');
  require(
    draft.draft['security'] == 'TLS',
    'Transport change must select compatible masking.',
  );
  require(
    draft.draft['port'] == '35001',
    'Transport change must retain the chosen port.',
  );
  require(
    draft.blockedChoices(security).containsKey('REALITY'),
    'Unsupported pairing stays disabled.',
  );
  draft.connectionStep = 'parameters';
  draft.draft['port'] = '70000';
  draft.advanceConnection();
  require(
    draft.connectionStep == 'parameters' &&
        draft.connectionErrors['port'] != null,
    'Invalid port must block the review step.',
  );
  draft.draft['port'] = '35001';
  draft.advanceConnection();
  require(
    draft.connectionStep == 'review',
    'Valid parameters must reach review.',
  );
  final other = ConnectionDraft(store: store, coreInstalled: (_) => true);
  final remote =
      ConnectionDraft(
          store: store,
          coreInstalled: (_) => true,
          engineAllowed: (id) => id == 'mihomo',
        )
        ..selectedProtocol = 'vless'
        ..selectedCore = 'mihomo'
        ..draft = {
          'name': 'Remote',
          'port': '35002',
          'transport': 'TCP',
          'security': 'REALITY',
        };
  require(
    remote.candidateEngines('vless').join(',') == 'mihomo',
    'Remote ingress must not offer an engine that the node cannot run.',
  );
  require(
    !remote.connectionSteps.contains('dependency') &&
        !remote.connectionSteps.contains('core'),
    'A remote-only route must not require a local engine installation.',
  );
  remote.connectionStep = 'core';
  remote.advanceConnection();
  require(
    remote.connectionStep == 'transport',
    'Remote ingress keeps the protocol configuration steps.',
  );
  require(
    other.draft.isEmpty && other.selectedProtocol == null,
    'A new constructor must not inherit another draft.',
  );
  store.protocols.remove('mihomo');
  require(
    !draft.connectionSteps.contains('core'),
    'A sole engine is implicit.',
  );
  const fixed = ProtocolDefinition(
    'shadowsocks',
    'Shadowsocks',
    [
      ProtocolField(
        'network',
        kind: 'choice',
        group: 'transport',
        defaultValue: 'TCP',
        options: ['TCP'],
      ),
    ],
    clientFieldBindings: {'transport': 'network'},
  );
  store.protocols['xray'] = [fixed];
  draft
    ..selectedProtocol = 'shadowsocks'
    ..connectionStep = 'core'
    ..draft = {'name': 'Proxy', 'port': '35002', 'network': 'TCP'};
  draft.advanceConnection();
  require(
    draft.connectionStep == 'parameters',
    'A fixed transport must not add a meaningless step.',
  );
  print('Connection draft decisions and validation passed.');
}
