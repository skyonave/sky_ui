import 'dart:io';

import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test(
    'schema 2 promotes existing device grants without changing keys or native hashes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sky-ui-recipient-migration-',
      );
      final path = '${directory.path}/panel.sqlite';
      var repository = PanelRepository(path, defaultAddress: 'example.test');
      final parentToken = secureToken(), childToken = secureToken();
      final data = PanelData(
        serverName: 'Panel',
        address: 'example.test',
        connections: [
          const StoredConnection(
            Connection(
              id: 'awg',
              name: 'AWG',
              coreId: 'amneziawg',
              protocolId: 'amneziawg',
              instanceId: 'amneziawg',
              port: 32131,
            ),
            {'privateKey': 'server-private'},
          ),
          const StoredConnection(
            Connection(
              id: 'vless',
              name: 'VLESS',
              coreId: 'xray',
              protocolId: 'vless',
              instanceId: 'xray',
              port: 35001,
            ),
            {'privateKey': 'reality-private'},
          ),
        ],
        recipients: [
          StoredRecipient(
            id: 'owner',
            name: 'Owner',
            enabled: true,
            token: parentToken,
          ),
          StoredRecipient(
            id: 'device',
            name: 'Phone',
            enabled: true,
            token: childToken,
          ),
          StoredRecipient(
            id: 'other',
            name: 'Owner / Phone',
            enabled: true,
            token: secureToken(),
          ),
          StoredRecipient(
            id: 'disabled',
            name: 'Disabled',
            enabled: false,
            token: secureToken(),
          ),
          StoredRecipient(
            id: 'disabled-device',
            name: 'Tablet',
            enabled: true,
            token: secureToken(),
          ),
        ],
        grants: const [
          AccessGrant(
            id: 'parent-awg',
            recipientId: 'owner',
            connectionId: 'awg',
            credentials: {
              'privateKey': 'parent-private',
              'publicKey': 'parent-public',
              'address': '10.66.0.2/32',
            },
          ),
          AccessGrant(
            id: 'device-awg',
            recipientId: 'device',
            connectionId: 'awg',
            credentials: {
              'privateKey': 'device-private',
              'publicKey': 'device-public',
              'address': '10.66.0.3/32',
            },
          ),
          AccessGrant(
            id: 'parent-vless',
            recipientId: 'owner',
            connectionId: 'vless',
            credentials: {'uuid': 'retained-vless-uuid'},
          ),
          AccessGrant(
            id: 'disabled-awg',
            recipientId: 'disabled-device',
            connectionId: 'awg',
            credentials: {
              'privateKey': 'disabled-private',
              'publicKey': 'disabled-public',
              'address': '10.66.0.4/32',
            },
          ),
        ],
      );
      try {
        repository.commit(
          data,
          'native-primary',
          configurations: {'amneziawg': 'native-awg', 'xray': 'native-xray'},
        );
        final revision = repository.revision;
        final hashes = {
          for (final id in ['primary', 'amneziawg', 'xray'])
            id: repository.instanceHash(id),
        };
        repository.close();
        final legacy = sqlite3.open(path);
        legacy.execute(
          'CREATE TABLE recipient_devices (id TEXT PRIMARY KEY REFERENCES recipients(id) ON DELETE CASCADE, parent_id TEXT NOT NULL REFERENCES recipients(id) ON DELETE CASCADE)',
        );
        legacy.execute('INSERT INTO recipient_devices VALUES (?,?)', [
          'device',
          'owner',
        ]);
        legacy.execute('INSERT INTO recipient_devices VALUES (?,?)', [
          'disabled-device',
          'disabled',
        ]);
        legacy.execute('PRAGMA user_version = 2');
        legacy.close();
        repository = PanelRepository(path, defaultAddress: 'example.test');
        final migrated = repository.read();
        expect(repository.revision, revision + 1);
        expect(migrated.recipients, hasLength(5));
        final child = migrated.recipients.firstWhere((u) => u.id == 'device');
        expect(child.name, 'Owner / Phone (2)');
        expect(child.enabled, isTrue);
        expect(child.token, childToken);
        expect(repository.recipientForToken(childToken), 'device');
        expect(repository.recipientForToken(parentToken), 'owner');
        expect(
          migrated.recipients
              .firstWhere((u) => u.id == 'disabled-device')
              .enabled,
          isFalse,
        );
        expect(
          migrated.grants
              .map((g) => (g.id, g.recipientId, g.connectionId))
              .toList(),
          data.grants
              .map((g) => (g.id, g.recipientId, g.connectionId))
              .toList(),
        );
        for (var i = 0; i < data.grants.length; i++) {
          expect(migrated.grants[i].credentials, data.grants[i].credentials);
        }
        expect(migrated.publicRecipient(child).connectionIds, ['awg']);
        for (final entry in hashes.entries)
          expect(repository.instanceHash(entry.key), entry.value);
        repository.close();
        repository = PanelRepository(path, defaultAddress: 'example.test');
        expect(repository.revision, revision + 1);
        expect(
          repository.read().recipients.firstWhere((u) => u.id == 'device').name,
          child.name,
        );
        final db = sqlite3.open(path);
        try {
          expect(db.select('PRAGMA user_version').first.values.single, 3);
          expect(
            db.select(
              "SELECT name FROM sqlite_master WHERE name='recipient_devices'",
            ),
            isEmpty,
          );
          expect(db.select('PRAGMA foreign_key_check'), isEmpty);
        } finally {
          db.close();
        }
      } finally {
        repository.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
