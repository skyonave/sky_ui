import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/application/access/recipient_presence.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';

void main() {
  test(
    'mihomo observations require the correct listener and active grant',
    () async {
      final data = PanelData(
        serverName: 'fixture',
        address: '127.0.0.1',
        connections: [
          for (final (id, protocol) in [
            ('c_vless', 'vless'),
            ('c_ss', 'shadowsocks'),
          ])
            StoredConnection(
              Connection(
                id: id,
                name: id,
                coreId: 'mihomo',
                protocolId: protocol,
                port: 32000,
              ),
              {},
            ),
        ],
        recipients: [
          for (final name in ['active', 'idle', 'revoked'])
            StoredRecipient(
              id: name,
              name: name,
              enabled: name != 'revoked',
              token: '',
            ),
        ],
        grants: [
          for (final name in ['active', 'idle', 'revoked'])
            AccessGrant(
              id: 'g_$name',
              recipientId: name,
              connectionId: 'c_vless',
              credentials: {},
            ),
          const AccessGrant(
            id: 'g_ss',
            recipientId: 'active',
            connectionId: 'c_ss',
            credentials: {'port': '32000'},
          ),
        ],
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var now = DateTime.utc(2026, 1, 1);
      var response = <String, Object?>{
        'connections': [
          for (final (name, user) in [
            ('sky-ui/c_vless', 'g_active'),
            ('sky-ui/c_vless', 'g_revoked'),
            ('sky-ui/c_other', 'g_idle'),
            ('sky-ui/c_ss/g_ss', ''),
          ])
            {
              'id': '$name/$user',
              'start': now.toIso8601String(),
              'upload': 3,
              'download': 0,
              'metadata': {'inboundName': name, 'inboundUser': user},
            },
        ],
      };
      server.listen((request) {
        expect(request.uri.path, '/connections');
        expect(request.headers.value('authorization'), 'Bearer fixture');
        request.response.write(jsonEncode(response));
        request.response.close();
      });
      final adapter = MihomoAdapter(
        const NativeCommandRunner(),
        now: () => now,
      );
      final core = ManagedCore(
        id: 'primary',
        coreId: 'mihomo',
        service: 'fixture',
        binary: '',
        directory: '',
        configuration: '',
        controller: Uri.parse('http://127.0.0.1:${server.port}'),
        secret: 'fixture',
      );
      expect(await adapter.presence(core, data), {
        'g_active': RecipientPresence.online,
        'g_idle': RecipientPresence.offline,
        'g_ss': RecipientPresence.online,
      });
      now = now.add(const Duration(seconds: 9));
      expect(
        (await adapter.presence(core, data))['g_active'],
        RecipientPresence.online,
      );
      now = now.add(const Duration(seconds: 1));
      expect(
        (await adapter.presence(core, data))['g_active'],
        RecipientPresence.offline,
      );
      final first = (response['connections'] as List).first as Map;
      first['upload'] = 4;
      expect(
        (await adapter.presence(core, data))['g_active'],
        RecipientPresence.online,
      );
      response = {'connections': null};
      expect(
        (await adapter.presence(core, data))['g_active'],
        RecipientPresence.online,
      );
      now = now.add(const Duration(seconds: 10));
      expect(
        (await adapter.presence(core, data)).values,
        everyElement(RecipientPresence.offline),
      );
      response = {};
      expect(await adapter.presence(core, data), isEmpty);
    },
  );

  test('presence does not turn missing evidence into offline', () {
    expect(
      combinePresence([
        RecipientPresence.offline,
        RecipientPresence.unavailable,
      ]),
      RecipientPresence.unavailable,
    );
    expect(
      combinePresence([RecipientPresence.recent, RecipientPresence.online]),
      RecipientPresence.online,
    );
    expect(
      combinePresence([
        RecipientPresence.recent,
        RecipientPresence.unavailable,
      ]),
      RecipientPresence.recent,
    );
    expect(combinePresence([]), RecipientPresence.offline);
  });
}
