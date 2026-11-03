import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:bcrypt/bcrypt.dart';
import 'package:crypto/crypto.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../shared/api_exception.dart';

String _random() => base64Url
    .encode(List.generate(32, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');
String _hash(String text) => sha256.convert(utf8.encode(text)).toString();
// Keep isolate closures outside the service so they cannot capture SQLite state.
Future<bool> _checkPassword(String password, String hash) => Isolate.run(
  () =>
      BCrypt.checkpw(password, hash.replaceFirst(RegExp(r'^\$2y\$'), r'$2b$')),
);
Future<String> _hashPassword(String password) =>
    Isolate.run(() => BCrypt.hashpw(password, BCrypt.gensalt(logRounds: 12)));
bool _equal(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

class OwnerIdentity {
  const OwnerIdentity(this.id, this.csrf, this.username);
  final String id, csrf, username;
}

class OwnerLogin {
  const OwnerLogin(this.token, this.state);
  final String token;
  final OwnerState state;
}

class OwnerAuth {
  OwnerAuth(String path, {required this.secure, DateTime Function()? clock})
    : _db = sqlite3.open(path),
      _clock = clock ?? DateTime.now {
    _db.execute('PRAGMA journal_mode=WAL');
    _db.execute('PRAGMA synchronous=FULL');
    _db.execute('PRAGMA busy_timeout=5000');
    final version = _db.select('PRAGMA user_version').single.values.first;
    if (version != 0 && version != 1) {
      _db.close();
      throw StateError('Unsupported owner database version.');
    }
    _db.execute(
      'CREATE TABLE IF NOT EXISTS owner (id INTEGER PRIMARY KEY CHECK(id=1),username TEXT NOT NULL,password_hash TEXT NOT NULL,generation INTEGER NOT NULL,seed_hash TEXT NOT NULL)',
    );
    _db.execute(
      'CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY,token_hash TEXT NOT NULL UNIQUE,csrf TEXT NOT NULL,created INTEGER NOT NULL,seen INTEGER NOT NULL,expires INTEGER NOT NULL,ip TEXT NOT NULL,agent TEXT NOT NULL)',
    );
    _db.execute('PRAGMA user_version=1');
  }
  final Database _db;
  final bool secure;
  final DateTime Function() _clock;
  final _attempts = <String, ({int start, int count})>{};
  int _workers = 0, _globalStart = 0, _globalCount = 0;
  static const lifetime = Duration(hours: 12), idle = Duration(hours: 2);
  int get _now => _clock().millisecondsSinceEpoch;
  String get cookieName => secure ? '__Host-sky-ui' : 'sky-ui-dev';
  bool get configured => _owner != null;
  Row? get _owner => _db.select('SELECT * FROM owner WHERE id=1').firstOrNull;
  T _transaction<T>(T Function() fn) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      final result = fn();
      _db.execute('COMMIT');
      return result;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> initialize(String? seedFile) async {
    if (seedFile == null || !await File(seedFile).exists()) return;
    final file = File(seedFile);
    if ((await file.stat()).size > 1024)
      throw const FormatException('Invalid owner seed.');
    final text = (await file.readAsString()).trim(),
        parts = text.split(RegExp(r'\s+'));
    if (parts.length != 2 ||
        !validName(parts[0]) ||
        !RegExp(
          r'^\$2[aby]\$(0[4-9]|1[0-4])\$[./A-Za-z0-9]{53}$',
        ).hasMatch(parts[1]))
      throw const FormatException('Invalid owner seed.');
    final fingerprint = _hash(text);
    if (_owner?['seed_hash'] == fingerprint) return;
    _transaction(() {
      final generation = (_owner?['generation'] as int? ?? 0) + 1;
      _db.execute('INSERT OR REPLACE INTO owner VALUES(1,?,?,?,?)', [
        parts[0],
        parts[1],
        generation,
        fingerprint,
      ]);
      _db.execute('DELETE FROM sessions');
    });
  }

  static bool validName(String value) =>
      RegExp(r'^[a-zA-Z][a-zA-Z0-9_.-]{0,31}$').hasMatch(value);
  static bool validPassword(String value) =>
      value.runes.length >= 12 && utf8.encode(value).length <= 72;
  String? token(String? header) {
    final found = (header ?? '')
        .split(';')
        .map((v) => v.trim())
        .where((v) => v.startsWith('$cookieName='))
        .toList();
    if (found.length != 1) return null;
    final value = found.single.substring(cookieName.length + 1);
    return RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value) ? value : null;
  }

  OwnerIdentity? identify(String? cookie, {bool touch = true}) {
    final value = token(cookie);
    if (value == null) return null;
    final row = _db.select('SELECT * FROM sessions WHERE token_hash=?', [
      _hash(value),
    ]).firstOrNull;
    if (row == null) return null;
    if ((row['expires'] as int) <= _now ||
        (row['seen'] as int) + idle.inMilliseconds <= _now) {
      _db.execute('DELETE FROM sessions WHERE id=?', [row['id']]);
      return null;
    }
    final owner = _owner;
    if (owner == null) return null;
    if (touch && _now - (row['seen'] as int) >= 60000)
      _db.execute('UPDATE sessions SET seen=? WHERE id=?', [_now, row['id']]);
    return OwnerIdentity(
      row['id'] as String,
      row['csrf'] as String,
      owner['username'] as String,
    );
  }

  OwnerState state(OwnerIdentity? identity) => OwnerState(
    configured: configured,
    authenticated: identity != null,
    username: identity?.username,
    csrf: identity?.csrf,
    sessionId: identity?.id,
  );
  void csrf(OwnerIdentity identity, String value) {
    if (!_equal(identity.csrf, value))
      throw const ApiException('csrf_invalid', status: 403);
  }

  String cookie(String? token) =>
      '$cookieName=${token ?? ''}; Path=/; HttpOnly; SameSite=Strict; Max-Age=${token == null ? 0 : lifetime.inSeconds}${secure ? '; Secure' : ''}';
  void _limit(String ip) {
    final now = _now, window = const Duration(minutes: 5).inMilliseconds;
    _attempts.removeWhere((_, v) => now - v.start >= window);
    if (now - _globalStart >= window) {
      _globalStart = now;
      _globalCount = 0;
    }
    final attempts = _attempts[ip] ?? (start: now, count: 0);
    if (attempts.count >= 10 || _globalCount >= 40 || _workers >= 2)
      throw const ApiException('auth_rate_limited', status: 429);
    if (_attempts.length >= 1024 && !_attempts.containsKey(ip))
      throw const ApiException('auth_rate_limited', status: 429);
    _attempts[ip] = (start: attempts.start, count: attempts.count + 1);
    _globalCount++;
  }

  Future<bool> _verify(String password, String hash) async {
    if (_workers >= 2)
      throw const ApiException('auth_rate_limited', status: 429);
    _workers++;
    try {
      return await _checkPassword(password, hash);
    } finally {
      _workers--;
    }
  }

  OwnerLogin _issue(String ip, String agent) {
    final cleanAgent = agent.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '');
    _db.execute('DELETE FROM sessions WHERE expires<=? OR seen<=?', [
      _now,
      _now - idle.inMilliseconds,
    ]);
    final value = _random(), id = _random(), csrf = _random();
    _db.execute('INSERT INTO sessions VALUES(?,?,?,?,?,?,?,?)', [
      id,
      _hash(value),
      csrf,
      _now,
      _now,
      _now + lifetime.inMilliseconds,
      ip,
      cleanAgent.substring(0, min(cleanAgent.length, 256)),
    ]);
    final rows = _db.select(
      'SELECT id FROM sessions WHERE id<>? ORDER BY created DESC,id DESC',
      [id],
    );
    for (final row in rows.skip(9))
      _db.execute('DELETE FROM sessions WHERE id=?', [row['id']]);
    return OwnerLogin(
      value,
      state(OwnerIdentity(id, csrf, _owner!['username'] as String)),
    );
  }

  Future<OwnerLogin> login(
    String username,
    String password,
    String ip,
    String agent,
  ) async {
    if (!configured)
      throw const ApiException('auth_not_configured', status: 503);
    _limit(ip);
    if (username.length > 32 ||
        utf8.encode(password).length > 72 ||
        password.isEmpty)
      throw const ApiException('auth_invalid', status: 401);
    final owner = _owner!, generation = owner['generation'];
    final valid = await _verify(password, owner['password_hash'] as String);
    if (!valid ||
        username != owner['username'] ||
        _owner?['generation'] != generation)
      throw const ApiException('auth_invalid', status: 401);
    _attempts.remove(ip);
    return _transaction(() => _issue(ip, agent));
  }

  Future<OwnerLogin> change(
    OwnerIdentity identity, {
    required String currentPassword,
    String? username,
    String? password,
    required String ip,
    required String agent,
  }) async {
    _limit(ip);
    if (currentPassword.isEmpty || utf8.encode(currentPassword).length > 72)
      throw const ApiException('auth_invalid', status: 401);
    if (username != null && !validName(username))
      throw const ApiException('owner_name_invalid', status: 400);
    if (password != null && !validPassword(password))
      throw const ApiException('owner_password_invalid', status: 400);
    final owner = _owner!, generation = owner['generation'];
    if (!await _verify(currentPassword, owner['password_hash'] as String))
      throw const ApiException('auth_invalid', status: 401);
    var hash = owner['password_hash'] as String;
    if (password != null) {
      if (_workers >= 2)
        throw const ApiException('auth_rate_limited', status: 429);
      _workers++;
      try {
        hash = await _hashPassword(password);
      } finally {
        _workers--;
      }
    }
    return _transaction(() {
      if (_owner?['generation'] != generation ||
          !_db.select(
            'SELECT id FROM sessions WHERE id=? AND expires>? AND seen>?',
            [identity.id, _now, _now - idle.inMilliseconds],
          ).isNotEmpty)
        throw const ApiException('auth_required', status: 401);
      _db.execute(
        'UPDATE owner SET username=?,password_hash=?,generation=generation+1 WHERE id=1',
        [username ?? owner['username'], hash],
      );
      _db.execute('DELETE FROM sessions');
      _attempts.remove(ip);
      return _issue(ip, agent);
    });
  }

  List<OwnerSession> sessions(OwnerIdentity identity) => _db
      .select(
        'SELECT * FROM sessions WHERE expires>? AND seen>? ORDER BY created DESC',
        [_now, _now - idle.inMilliseconds],
      )
      .map(
        (r) => OwnerSession(
          id: r['id'] as String,
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            r['created'] as int,
            isUtc: true,
          ),
          lastSeen: DateTime.fromMillisecondsSinceEpoch(
            r['seen'] as int,
            isUtc: true,
          ),
          expiresAt: DateTime.fromMillisecondsSinceEpoch(
            r['expires'] as int,
            isUtc: true,
          ),
          ip: r['ip'] as String,
          agent: r['agent'] as String,
          current: r['id'] == identity.id,
        ),
      )
      .toList();
  void revoke(String id) =>
      _db.execute('DELETE FROM sessions WHERE id=?', [id]);
  void revokeOthers(OwnerIdentity identity) =>
      _db.execute('DELETE FROM sessions WHERE id<>?', [identity.id]);
  void close() => _db.close();
}
