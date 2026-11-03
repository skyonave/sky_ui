import 'dart:io';
import 'dart:convert';
import 'package:bcrypt/bcrypt.dart';
import 'package:sky_ui_api/src/features/auth/owner_auth.dart';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late OwnerAuth auth;
  late File seed;
  late DateTime now;
  const password = 'fixture-owner-password';
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sky-ui-owner-');
    seed = File('${directory.path}/seed');
    seed.writeAsStringSync(
      'admin ${BCrypt.hashpw(password, BCrypt.gensalt(logRounds: 4))}',
    );
    now = DateTime.utc(2026, 10, 31);
    auth = OwnerAuth(
      '${directory.path}/owner.sqlite',
      secure: true,
      clock: () => now,
    );
    await auth.initialize(seed.path);
  });
  tearDown(() async {
    auth.close();
    await directory.delete(recursive: true);
  });
  String cookie(String token) => '__Host-sky-ui=$token';
  test(
    'existing bcrypt credentials migrate; opaque tokens never appear in stored sessions or public DTOs',
    () async {
      final result = await auth.login(
        'admin',
        password,
        '203.0.113.8',
        'Test device',
      );
      expect(result.state.username, 'admin');
      expect(result.state.authenticated, true);
      expect(
        auth.cookie(result.token),
        allOf(
          contains('HttpOnly'),
          contains('Secure'),
          contains('SameSite=Strict'),
          contains('Path=/'),
        ),
      );
      final identity = auth.identify(cookie(result.token))!;
      expect(() => auth.csrf(identity, 'wrong'), throwsA(isA<ApiException>()));
      auth.csrf(identity, result.state.csrf!);
      final db = sqlite3.open('${directory.path}/owner.sqlite');
      expect(
        jsonEncode(
          db
              .select('SELECT * FROM sessions')
              .map((r) => Map<String, Object?>.from(r))
              .toList(),
        ),
        isNot(contains(result.token)),
      );
      db.close();
      expect(
        jsonEncode(auth.sessions(identity).map((v) => v.toJson()).toList()),
        isNot(contains(result.token)),
      );
    },
  );
  test(
    'logout and revoking other sessions remove server authorization',
    () async {
      final first = await auth.login('admin', password, '203.0.113.1', 'First');
      final second = await auth.login(
        'admin',
        password,
        '203.0.113.2',
        'Second',
      );
      final identity = auth.identify(cookie(second.token))!;
      auth.revokeOthers(identity);
      expect(auth.identify(cookie(first.token)), isNull);
      expect(auth.identify(cookie(second.token)), isNotNull);
      auth.revoke(identity.id);
      expect(auth.identify(cookie(second.token)), isNull);
    },
  );
  test(
    'username/password changes require current password, rotate sessions and survive restart with the old seed',
    () async {
      final first = await auth.login('admin', password, '203.0.113.1', 'First');
      final identity = auth.identify(cookie(first.token))!;
      await expectLater(
        auth.change(
          identity,
          currentPassword: 'incorrect',
          username: 'newadmin',
          ip: '203.0.113.1',
          agent: 'First',
        ),
        throwsA(isA<ApiException>()),
      );
      final renamed = await auth.change(
        identity,
        currentPassword: password,
        username: 'newadmin',
        ip: '203.0.113.1',
        agent: 'First',
      );
      expect(auth.identify(cookie(first.token)), isNull);
      expect(renamed.state.username, 'newadmin');
      final changed = await auth.change(
        auth.identify(cookie(renamed.token))!,
        currentPassword: password,
        password: 'replacement-owner-password',
        ip: '203.0.113.1',
        agent: 'First',
      );
      expect(auth.identify(cookie(renamed.token)), isNull);
      auth.close();
      auth = OwnerAuth(
        '${directory.path}/owner.sqlite',
        secure: true,
        clock: () => now,
      );
      await auth.initialize(seed.path);
      expect(auth.identify(cookie(changed.token)), isNotNull);
      await expectLater(
        auth.login('newadmin', password, '203.0.113.1', 'Old'),
        throwsA(isA<ApiException>()),
      );
      expect(
        (await auth.login(
          'newadmin',
          'replacement-owner-password',
          '203.0.113.1',
          'New',
        )).state.authenticated,
        true,
      );
    },
  );
  test(
    'a new CLI seed resets owner credentials and revokes existing sessions',
    () async {
      final first = await auth.login('admin', password, '203.0.113.1', 'First');
      seed.writeAsStringSync(
        'recovered ${BCrypt.hashpw('recovered-owner-password', BCrypt.gensalt(logRounds: 4))}',
      );
      await auth.initialize(seed.path);
      expect(auth.identify(cookie(first.token)), isNull);
      expect(
        (await auth.login(
          'recovered',
          'recovered-owner-password',
          '203.0.113.1',
          'New',
        )).state.username,
        'recovered',
      );
    },
  );
  test('idle/absolute expiry and duplicate cookies fail closed', () async {
    final first = await auth.login('admin', password, '203.0.113.1', 'First');
    expect(
      auth.identify('${cookie(first.token)}; ${cookie(first.token)}'),
      isNull,
    );
    now = now.add(const Duration(hours: 2));
    expect(auth.identify(cookie(first.token)), isNull);
    final active = await auth.login('admin', password, '203.0.113.1', 'First');
    for (var i = 0; i < 12; i++) {
      now = now.add(const Duration(hours: 1));
      auth.identify(cookie(active.token));
    }
    expect(auth.identify(cookie(active.token)), isNull);
  });
  test('repeated failed logins are bounded', () async {
    for (var i = 0; i < 10; i++)
      await expectLater(
        auth.login('admin', 'wrong', '203.0.113.1', 'Bad'),
        throwsA(isA<ApiException>()),
      );
    try {
      await auth.login('admin', password, '203.0.113.1', 'Bad');
      fail('Expected rate limit');
    } on ApiException catch (e) {
      expect(e.code, 'auth_rate_limited');
    }
  });

  test(
    'Caddy bcrypt variants and UTF-8 limits are handled consistently',
    () async {
      final hash = BCrypt.hashpw(password, BCrypt.gensalt(logRounds: 4));
      for (final prefix in [r'$2a$', r'$2b$', r'$2y$']) {
        seed.writeAsStringSync('admin ${hash.replaceRange(0, 4, prefix)}');
        await auth.initialize(seed.path);
        expect(
          (await auth.login(
            'admin',
            password,
            '203.0.113.1',
            'First',
          )).state.authenticated,
          true,
        );
      }
      expect(OwnerAuth.validPassword('я' * 36), true);
      expect(OwnerAuth.validPassword('я' * 37), false);
      expect(OwnerAuth.validPassword('🙂' * 6), false);
    },
  );
  test(
    'session limit retains the newly issued session even when timestamps tie',
    () async {
      final tokens = <String>[];
      for (var i = 0; i < 11; i++)
        tokens.add(
          (await auth.login(
            'admin',
            password,
            '203.0.113.1',
            'Browser $i',
          )).token,
        );
      final latest = auth.identify(cookie(tokens.last))!;
      expect(auth.sessions(latest), hasLength(10));
      expect(auth.identify(cookie(tokens.last)), isNotNull);
    },
  );

  test('an in-flight owner change cannot restore a revoked session', () async {
    final result = await auth.login(
      'admin',
      password,
      '203.0.113.1',
      'Browser',
    );
    final identity = auth.identify(cookie(result.token))!;
    final pending = auth.change(
      identity,
      currentPassword: password,
      username: 'changed',
      ip: '203.0.113.1',
      agent: 'Browser',
    );
    auth.revoke(identity.id);
    await expectLater(
      pending,
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'auth_required'),
      ),
    );
    expect(
      (await auth.login(
        'admin',
        password,
        '203.0.113.1',
        'Browser',
      )).state.username,
      'admin',
    );
  });
  test(
    'changing the CLI seed invalidates a login already verifying the previous hash',
    () async {
      final pending = auth.login('admin', password, '203.0.113.1', 'Browser');
      seed.writeAsStringSync(
        'recovered ${BCrypt.hashpw('replacement-password', BCrypt.gensalt(logRounds: 4))}',
      );
      await auth.initialize(seed.path);
      try {
        final result = await pending;
        expect(auth.identify(cookie(result.token)), isNull);
      } on ApiException catch (e) {
        expect(e.code, 'auth_invalid');
      }
    },
  );
}
