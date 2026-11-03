import 'dart:convert';

import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../application/access/records.dart';
import '../../application/access/repository.dart';

export '../../application/access/repository.dart'
    show DeploymentIntent, AccessRepository;

class PanelRepository implements AccessRepository {
  PanelRepository(String path, {required String defaultAddress})
    : _defaultAddress = defaultAddress,
      _db = sqlite3.open(path) {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = FULL');
    _db.execute('PRAGMA busy_timeout = 5000');
    final schema = _db.select('PRAGMA user_version').first.values.first as int;
    if (schema != 0 && schema != 1) {
      _db.close();
      throw StateError('Unsupported panel database version.');
    }
    transaction(() {
      _db.execute(
        'CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      _db.execute(
        'CREATE TABLE IF NOT EXISTS connections (id TEXT PRIMARY KEY, position INTEGER NOT NULL, value TEXT NOT NULL, secrets TEXT NOT NULL)',
      );
      _db.execute(
        'CREATE TABLE IF NOT EXISTS recipients (id TEXT PRIMARY KEY, position INTEGER NOT NULL, name TEXT NOT NULL, enabled INTEGER NOT NULL, token TEXT NOT NULL, token_hash TEXT NOT NULL UNIQUE)',
      );
      _db.execute(
        'CREATE TABLE IF NOT EXISTS grants (id TEXT PRIMARY KEY, recipient_id TEXT NOT NULL REFERENCES recipients(id), connection_id TEXT NOT NULL REFERENCES connections(id), credentials TEXT NOT NULL, UNIQUE(recipient_id,connection_id))',
      );
      _db.execute(
        'CREATE TABLE IF NOT EXISTS deployment (id INTEGER PRIMARY KEY CHECK(id = 1), previous TEXT NOT NULL, candidate TEXT NOT NULL, was_running INTEGER NOT NULL)',
      );
      _db.execute('PRAGMA user_version = 1');
      _db.execute('INSERT OR IGNORE INTO metadata VALUES (?,?)', [
        'revision',
        '0',
      ]);
      _db.execute('INSERT OR IGNORE INTO metadata VALUES (?,?)', [
        'serverName',
        defaultAddress,
      ]);
      _db.execute('INSERT OR IGNORE INTO metadata VALUES (?,?)', [
        'address',
        defaultAddress,
      ]);
      _db.execute('INSERT OR IGNORE INTO metadata VALUES (?,?)', [
        'addressFollowsOrigin',
        metadata('address') == defaultAddress ? '1' : '0',
      ]);
    });
  }
  final Database _db;
  final String _defaultAddress;
  T transaction<T>(T Function() operation) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final value = operation();
      _db.execute('COMMIT');
      return value;
    } on Object {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  String? metadata(String key) =>
      _db.select('SELECT value FROM metadata WHERE key = ?', [
            key,
          ]).firstOrNull?['value']
          as String?;
  void _set(String key, String value) =>
      _db.execute('INSERT OR REPLACE INTO metadata VALUES (?,?)', [key, value]);
  int get revision => int.parse(metadata('revision')!);
  String? get configurationHash => metadata('configurationHash');
  DeploymentIntent? get pending {
    final row = _db
        .select(
          'SELECT previous,candidate,was_running FROM deployment WHERE id = 1',
        )
        .firstOrNull;
    return row == null
        ? null
        : DeploymentIntent(
            row['previous'] as String,
            row['candidate'] as String,
            row['was_running'] == 1,
          );
  }

  void prepare(DeploymentIntent intent) => _db.execute(
    'INSERT INTO deployment VALUES (1,?,?,?)',
    [intent.previous, intent.candidate, intent.wasRunning ? 1 : 0],
  );
  void clearPending() => _db.execute('DELETE FROM deployment WHERE id = 1');
  PanelData read() => PanelData(
    coreSettings: (jsonDecode(metadata('coreSettings') ?? '{}') as Map).map(
      (k, v) => MapEntry(k as String, Map<String, String>.from(v as Map)),
    ),
    serverName: metadata('serverName')!,
    address: metadata('addressFollowsOrigin') == '1'
        ? _defaultAddress
        : metadata('address')!,
    connections: _db
        .select('SELECT value,secrets FROM connections ORDER BY position')
        .map(
          (r) => StoredConnection(
            Connection.fromJson(
              jsonDecode(r['value'] as String) as Map<String, dynamic>,
            ),
            Map<String, String>.from(jsonDecode(r['secrets'] as String) as Map),
          ),
        )
        .toList(),
    recipients: _db
        .select('SELECT * FROM recipients ORDER BY position')
        .map(
          (r) => StoredRecipient(
            id: r['id'] as String,
            name: r['name'] as String,
            enabled: r['enabled'] == 1,
            token: r['token'] as String,
          ),
        )
        .toList(),
    grants: _db
        .select('SELECT * FROM grants ORDER BY rowid')
        .map(
          (r) => AccessGrant(
            id: r['id'] as String,
            recipientId: r['recipient_id'] as String,
            connectionId: r['connection_id'] as String,
            credentials: Map<String, String>.from(
              jsonDecode(r['credentials'] as String) as Map,
            ),
          ),
        )
        .toList(),
  );
  String? recipientForToken(String token) =>
      _db.select('SELECT id FROM recipients WHERE token_hash = ?', [
            digest(token),
          ]).firstOrNull?['id']
          as String?;
  String? instanceHash(String id) =>
      metadata('configurationHash:$id') ??
      (id == 'primary' ? configurationHash : null);

  void commit(
    PanelData data,
    String configuration, {
    Map<String, String> configurations = const {},
  }) => transaction(() {
    _db.execute('DELETE FROM grants');
    _db.execute('DELETE FROM recipients');
    _db.execute('DELETE FROM connections');
    for (var i = 0; i < data.connections.length; i++) {
      final c = data.connections[i];
      _db.execute('INSERT INTO connections VALUES (?,?,?,?)', [
        c.value.id,
        i,
        jsonEncode(c.value.toJson()),
        jsonEncode(c.secrets),
      ]);
    }
    for (var i = 0; i < data.recipients.length; i++) {
      final u = data.recipients[i];
      _db.execute('INSERT INTO recipients VALUES (?,?,?,?,?,?)', [
        u.id,
        i,
        u.name,
        u.enabled ? 1 : 0,
        u.token,
        digest(u.token),
      ]);
    }
    for (final g in data.grants) {
      _db.execute('INSERT INTO grants VALUES (?,?,?,?)', [
        g.id,
        g.recipientId,
        g.connectionId,
        jsonEncode(g.credentials),
      ]);
    }
    _set('serverName', data.serverName);
    _set('coreSettings', jsonEncode(data.coreSettings));
    _set('address', data.address);
    _set('addressFollowsOrigin', data.address == _defaultAddress ? '1' : '0');
    _set('revision', '${revision + 1}');
    _set('configurationHash', digest(configuration));
    _set('configuration', configuration);
    for (final entry in configurations.entries) {
      _set('configurationHash:${entry.key}', digest(entry.value));
    }
    clearPending();
  });
  void close() => _db.close();
}
