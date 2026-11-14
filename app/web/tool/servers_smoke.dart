import 'dart:async';
import 'package:jaspr/client.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:sky_ui_web/src/features/servers/servers_page.dart';
import 'package:sky_ui_web/src/shared/api/api_client.dart';
import 'package:sky_ui_web/src/shared/localization/strings.dart';
import 'package:web/web.dart' as web;

final api = _Api();
var refreshes = 0;

void main() {
  AppStrings.defaultLocale = 'en';
  runApp(
    ServersPage(
      api: api,
      localName: 'Panel',
      onChanged: () async {
        refreshes++;
      },
    ),
    attachTo: '#app',
  );
  unawaited(check());
}

Future<void> frame() => Future<void>.delayed(const Duration(milliseconds: 80));
void require(bool value, String message) {
  if (!value) throw StateError(message);
}

web.HTMLElement button(String text) {
  final list = web.document.querySelectorAll('button');
  return [
    for (var i = 0; i < list.length; i++) list.item(i) as web.HTMLElement,
  ].singleWhere((e) => e.textContent?.trim() == text);
}

Future<void> check() async {
  final result = web.document.querySelector('#result')!;
  try {
    await frame();
    button('Edit server').click();
    await frame();
    final fields = web.document.querySelectorAll('.server-edit input');
    require(fields.length == 2, 'Name and address must both be editable.');
    final name = fields.item(0) as web.HTMLInputElement;
    name.value = 'Germany';
    name.dispatchEvent(web.Event('input', web.EventInit(bubbles: true)));
    final address = fields.item(1) as web.HTMLInputElement;
    address.value = 'de.example.net';
    address.dispatchEvent(web.Event('input', web.EventInit(bubbles: true)));
    button('Save').click();
    await frame();
    require(
      api.node.name == 'Germany' && api.node.endpoint == 'de.example.net',
      'Save must preserve both edits.',
    );
    require(refreshes == 1, 'Other views must refresh advertised metadata.');
    require(
      web.document.querySelector('.server-edit') == null,
      'Edit form must close on success.',
    );
    button('Check').click();
    await frame();
    require(
      web.document.querySelectorAll('.server-core-row').length == 4,
      'All four engine rows must appear.',
    );
    button('Install').click();
    await frame();
    require(
      api.installed == 'amneziawg',
      'Install must target the missing engine on the remote node.',
    );
    require(
      web.document
          .querySelector('.server-core-row:last-child')!
          .textContent!
          .contains('Stopped'),
      'Successful installation must refresh this node inventory.',
    );
    result.textContent =
        'PASS: rename, client domain, refresh, four engines, remote AWG installation';
  } catch (error) {
    result.textContent = 'FAIL: $error';
  }
}

class _Api extends ApiClient {
  ServerNode node = const ServerNode(
    id: 'node_fixture',
    name: 'DE',
    host: '192.0.2.5',
    port: 22,
    publicKey: 'fixture',
  );
  String? installed;
  @override
  Future<({bool enabled, List<ServerNode> nodes})> servers() async =>
      (enabled: true, nodes: [node]);
  @override
  Future<void> updateServerDetails(
    String id,
    String name,
    String endpoint,
  ) async {
    require(id == node.id, 'Wrong node');
    node = ServerNode(
      id: id,
      name: name,
      host: node.host,
      port: 22,
      publicKey: 'fixture',
      endpoint: endpoint,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> serverEngines(
    String id, {
    bool updates = false,
  }) async => [
    for (final core in ['mihomo', 'sing-box', 'xray', 'amneziawg'])
      {
        'coreId': core,
        'installed': core != 'amneziawg' || installed == core,
        'state': 'inactive',
        'version': null,
      },
  ];
  @override
  Future<void> installServerEngine(String id, String core) async {
    require(id == node.id, 'Wrong install node');
    installed = core;
  }
}
