import 'dart:convert';
import 'package:sky_ui_api/src/engines/mihomo/settings.dart';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';

void main() {
  const baseline =
      '{"mode":"direct","log-level":"warning","secret":"private",'
      '"dns":{"enable":false,"nameserver":["9.9.9.9"],"nameserver-policy":{"+.example.org":"1.1.1.1"}},'
      '"rules":["DOMAIN,old.example,DIRECT"],"sub-rules":{"foreign":["MATCH,DIRECT"]},'
      '"listeners":[{"name":"foreign","type":"socks","port":1234}]}';
  Map<String, Object?> listener() => {'name': 'sky-ui/c1', 'proxy': 'DIRECT'};
  test('schema roundtrip never leaks native secrets or private baseline', () {
    final values = MihomoSettings.prepare(baseline, null, {
      'logLevel': 'debug',
    });
    final form = CoreSettings(
      instanceId: 'primary',
      coreId: 'mihomo',
      revision: 3,
      fields: MihomoSettings.fields,
      values: MihomoSettings.read(baseline, values),
    );
    final json = jsonEncode(form.toJson());
    expect(json, isNot(contains('private')));
    expect(json, isNot(contains('_baseline')));
    expect(CoreSettings.fromJson(jsonDecode(json)).values['logLevel'], 'debug');
  });
  test('unmanaged defaults reflect current native log level', () {
    final values = MihomoSettings.read(baseline, null);
    expect(values['logLevel'], 'warning');
    expect(values['dnsMode'], 'existing');
    expect(values['blockPrivate'], 'false');
  });
  test('log-only edit preserves DNS, modes, rules and unrelated secrets', () {
    final base = MihomoSettings.document(baseline),
        expected = MihomoSettings.document(baseline);
    final owned = listener();
    MihomoSettings.apply(base, [
      owned,
    ], MihomoSettings.prepare(baseline, null, {'logLevel': 'debug'}));
    expected['log-level'] = 'debug';
    expect(base, expected);
    expect(owned['proxy'], 'DIRECT');
  });
  test('custom DNS has trusted DoH/DoT and no public listening socket', () {
    final base = MihomoSettings.document(baseline);
    final values = MihomoSettings.prepare(baseline, null, {
      'dnsMode': 'custom',
      'resolvers':
          'https://dns.google/dns-query\ntls://one.one.one.one\n1.1.1.1',
    });
    MihomoSettings.apply(base, [], values);
    final dns = base['dns'] as Map;
    expect(dns['nameserver'], hasLength(3));
    expect(dns['listen'], isNull);
    expect(dns['default-nameserver'], ['system']);
    expect(dns.containsKey('nameserver-policy'), false);
    final restore = MihomoSettings.prepare(jsonEncode(base), values, {
      'dnsMode': 'existing',
    });
    MihomoSettings.apply(base, [], restore);
    expect(base['dns'], MihomoSettings.document(baseline)['dns']);
  });
  test('system DNS and inherited missing DNS roundtrip', () {
    final base = <String, Object?>{'mode': 'direct'};
    final values = MihomoSettings.prepare(jsonEncode(base), null, {
      'dnsMode': 'system',
    });
    MihomoSettings.apply(base, [], values);
    expect((base['dns'] as Map)['nameserver'], ['system']);
    final restore = MihomoSettings.prepare(jsonEncode(base), values, {
      'dnsMode': 'existing',
    });
    MihomoSettings.apply(base, [], restore);
    expect(base.containsKey('dns'), false);
  });
  test(
    'private rules are scoped to owned listeners and precede explicit allow',
    () {
      final base = MihomoSettings.document(baseline), owned = listener();
      final values = MihomoSettings.prepare(baseline, null, {
        'blockPrivate': 'true',
        'accessRules':
            '[{"type":"cidr","target":"10.0.0.0/8","action":"allow"}]',
      });
      MihomoSettings.apply(base, [owned], values);
      expect(base['mode'], 'rule');
      expect(base['rules'], ['MATCH,DIRECT']);
      expect(owned.containsKey('proxy'), false);
      final sub = base['sub-rules'] as Map, rules = sub[owned['rule']] as List;
      expect(sub['foreign'], ['MATCH,DIRECT']);
      expect(
        rules.indexOf('IP-CIDR,10.0.0.0/8,REJECT'),
        lessThan(rules.indexOf('IP-CIDR,10.0.0.0/8,DIRECT')),
      );
      expect(rules, contains('IP-CIDR6,fc00::/7,REJECT'));
      expect(rules.last, 'MATCH,DIRECT');
      expect((base['listeners'] as List).single['name'], 'foreign');
      expect(base['secret'], 'private');
      final restore = MihomoSettings.prepare(jsonEncode(base), values, {
        'blockPrivate': 'false',
        'accessRules': '[]',
      });
      MihomoSettings.apply(base, [listener()], restore);
      expect(base['mode'], 'direct');
      expect(base['rules'], MihomoSettings.document(baseline)['rules']);
      expect(base['sub-rules'], {
        'foreign': ['MATCH,DIRECT'],
      });
    },
  );
  test('existing rule mode preserves native rules and connection fallback', () {
    const native = '{"mode":"rule","rules":["MATCH,REJECT"]}';
    final base = MihomoSettings.document(native);
    final owned = {'name': 'sky-ui/one', 'proxy': 'custom-outbound'};
    MihomoSettings.apply(base, [
      owned,
    ], MihomoSettings.prepare(native, null, {'blockPrivate': 'true'}));
    expect(base['rules'], ['MATCH,REJECT']);
    expect(
      ((base['sub-rules'] as Map)[owned['rule']] as List).last,
      'MATCH,custom-outbound',
    );
  });
  test(
    'foreign subrules in bypass mode fail explicitly instead of changing traffic',
    () {
      const native =
          '{"mode":"direct","listeners":[{"name":"foreign","rule":"mine"}]}';
      expect(
        () => MihomoSettings.apply(
          MihomoSettings.document(native),
          [],
          MihomoSettings.prepare(native, null, {'blockPrivate': 'true'}),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'core_settings_routing_conflict',
          ),
        ),
      );
    },
  );
  test(
    'invalid resolvers, rules and unsupported fields never get silently dropped',
    () {
      for (final input in <Map<String, String>>[
        {'dnsMode': 'custom', 'resolvers': ''},
        {'dnsMode': 'custom', 'resolvers': 'http://dns.example/dns-query'},
        {
          'dnsMode': 'custom',
          'resolvers': 'https://dns.example/#skip-cert-verify',
        },
        {'dnsMode': 'custom', 'resolvers': 'tls://dns.example:99999'},
        {
          'dnsMode': 'custom',
          'resolvers': 'https://user:password@dns.example/dns-query',
        },
        {'logLevel': 'trace'},
        {'arbitrary': 'value'},
        {'accessRules': '[{"type":"cidr","target":"::/129","action":"allow"}]'},
        {
          'accessRules':
              '[{"type":"domain","target":"example.com,REJECT","action":"allow"}]',
        },
        {'accessRules': '[{"target":"example.com"}]'},
        {'accessRules': 'not json'},
        {'blockPrivate': 'yes'},
      ]) {
        expect(
          () => MihomoSettings.prepare(baseline, null, input),
          throwsA(isA<ApiException>()),
          reason: '$input',
        );
      }
    },
  );
  test('instance snapshots do not share mutable settings', () {
    final data = PanelData(
      serverName: 'test',
      address: 'example.com',
      coreSettings: {
        'a': {'logLevel': 'info'},
        'b': {'logLevel': 'debug'},
      },
    );
    final copy = data.copy(), scoped = data.forInstance('a');
    scoped.coreSettings['a']!['logLevel'] = 'error';
    copy.coreSettings['b']!['logLevel'] = 'silent';
    expect(data.coreSettings['a']!['logLevel'], 'info');
    expect(data.coreSettings['b']!['logLevel'], 'debug');
    expect(scoped.coreSettings.keys, ['a']);
  });
}
