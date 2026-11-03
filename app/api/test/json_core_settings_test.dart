import 'dart:convert';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/engines/sing_box/settings.dart';
import 'package:sky_ui_api/src/engines/xray/settings.dart';
import 'package:sky_ui_api/src/engines/proxy/configuration.dart';
import 'package:test/test.dart';
import 'core_manager_test.dart' show FakeSupervisor;

void main() {
  for (final id in ['sing-box', 'xray']) {
    final routeKey = id == 'xray' ? 'routing' : 'route';
    Map<String, dynamic> baseline() => {
      'log': id == 'xray'
          ? {
              'loglevel': 'warning',
              'access': 'original-access.log',
              'dnsLog': true,
            }
          : {'level': 'warn', 'timestamp': true},
      'dns': id == 'xray'
          ? {
              'servers': ['9.9.9.9'],
              'hosts': {'private.test': '127.0.0.1'},
            }
          : {
              'servers': [
                {'type': 'udp', 'tag': 'original-dns', 'server': '9.9.9.9'},
              ],
              'final': 'original-dns',
            },
      routeKey: {'rules': [], if (id == 'sing-box') 'final': 'direct'},
      'inbounds': [
        id == 'xray'
            ? {'tag': 'foreign', 'protocol': 'socks'}
            : {'tag': 'foreign', 'type': 'socks'},
      ],
      'outbounds': [
        id == 'xray'
            ? {'protocol': 'freedom', 'tag': 'direct'}
            : {'type': 'direct', 'tag': 'direct'},
      ],
      'owner-native': {'preserved': true},
    };
    Map<String, String> prepare(
      Map<String, dynamic> base,
      Map<String, String> input, [
      Map<String, String>? stored,
    ]) => id == 'xray'
        ? XraySettings.prepare(jsonEncode(base), stored, input)
        : SingBoxSettings.prepare(jsonEncode(base), stored, input);
    void apply(
      Map<String, dynamic> base,
      Map<String, String> values, {
      List<String> tags = const ['sky-owned'],
    }) {
      if (id == 'xray') {
        XraySettings.apply(base, tags, values);
      } else {
        SingBoxSettings.apply(base, tags, values);
      }
    }

    test(
      '$id log edits preserve unrelated native configuration and public form omits baseline',
      () {
        final base = baseline(),
            before = baseline(),
            values = prepare(baseline(), {'logLevel': 'debug'});
        apply(base, values);
        expect(base['dns'], before['dns']);
        expect(base[routeKey], before[routeKey]);
        expect(base['inbounds'], before['inbounds']);
        expect(base['outbounds'], before['outbounds']);
        expect(base['owner-native'], before['owner-native']);
        expect(
          (base['log'] as Map)[id == 'xray' ? 'loglevel' : 'level'],
          'debug',
        );
        final public = id == 'xray'
            ? XraySettings.read(jsonEncode(base), values)
            : SingBoxSettings.read(jsonEncode(base), values);
        expect(public.containsKey('_baseline'), false);
      },
    );
    test('$id DNS roundtrip restores the original native policy', () {
      final base = baseline(), before = baseline();
      final values = prepare(base, {
        'dnsMode': 'custom',
        'resolvers': 'https://dns.google/dns-query',
      });
      apply(base, values);
      expect(base['dns'], isNot(equals(before['dns'])));
      if (id == 'xray') {
        expect((base['dns'] as Map)['servers'], [
          'https+local://dns.google/dns-query',
        ]);
        expect(
          (base['outbounds'] as List).last['settings']['domainStrategy'],
          'UseIP',
        );
      } else {
        final dns = base['dns'] as Map,
            upstream = (dns['servers'] as List).last;
        expect(upstream['type'], 'https');
        expect(upstream['domain_resolver'], SingBoxSettings.systemTag);
        expect(upstream['path'], '/dns-query');
        expect(upstream['tls'], isNull);
      }
      final restore = prepare(base, {'dnsMode': 'existing'}, values);
      apply(base, restore);
      expect(base['dns'], before['dns']);
      expect(base[routeKey], before[routeKey]);
      expect(base['outbounds'], before['outbounds']);
    });
    test(
      '$id ordered access is scoped and cannot override private protection',
      () {
        final base = baseline();
        final values = prepare(base, {
          'blockPrivate': 'true',
          'accessRules':
              '[{"type":"cidr","target":"10.0.0.0/8","action":"allow"},{"type":"domain","target":"example.com","action":"block"}]',
        });
        apply(base, values);
        final rules = (base[routeKey] as Map)['rules'] as List;
        final relevant = id == 'xray' ? rules : rules.skip(1).toList();
        expect(
          relevant[0][id == 'xray' ? 'ip' : 'ip_cidr'],
          contains('10.0.0.0/8'),
        );
        expect(
          relevant[1][id == 'xray' ? 'outboundTag' : 'outbound'],
          'sky-ui/settings/direct',
        );
        for (final rule in rules) {
          expect(rule[id == 'xray' ? 'inboundTag' : 'inbound'], ['sky-owned']);
        }
        expect((base['inbounds'] as List).single['tag'], 'foreign');
        final restored = prepare(base, {
          'blockPrivate': 'false',
          'accessRules': '[]',
        }, values);
        apply(base, restored);
        expect(base[routeKey], baseline()[routeKey]);
        expect(base['outbounds'], baseline()['outbounds']);
      },
    );
    test(
      '$id empty managed listener set never emits an unscoped access rule',
      () {
        final base = baseline();
        apply(
          base,
          prepare(base, {
            'blockPrivate': 'true',
            'accessRules':
                '[{"type":"domain","target":"example.com","action":"block"}]',
          }),
          tags: [],
        );
        expect((base[routeKey] as Map)['rules'], isEmpty);
        expect(base['outbounds'], baseline()['outbounds']);
      },
    );
    test('$id unsupported fields and resolver overrides are rejected', () {
      for (final input in <Map<String, String>>[
        {'_baseline': '{}'},
        {'logLevel': 'unsupported'},
        {'accessRules': ''},
        {
          'dnsMode': 'custom',
          'resolvers': 'https://dns.example/#skip-cert-verify',
        },
        {
          'dnsMode': 'custom',
          'resolvers': 'https://user:pass@dns.example/dns-query',
        },
      ]) {
        expect(() => prepare(baseline(), input), throwsA(isA<ApiException>()));
      }
    });
    test(
      '$id connection compilation preserves unmanaged sections without managed settings',
      () {
        final core = ManagedCore(
          id: id,
          coreId: id,
          service: 'fixture',
          binary: '/unused',
          directory: '/unused',
          configuration: '/unused/config.json',
          controller: Uri.parse('http://127.0.0.1:0'),
          secret: '',
        );
        final codec = ProxyConfiguration(
          id,
          core: core,
          supervisor: FakeSupervisor(),
        );
        final base = baseline();
        final result = jsonDecode(
          codec.compile(
            PanelData(serverName: 'test', address: 'example.com'),
            core,
            jsonEncode(base),
          ),
        );
        expect(result, base);
      },
    );
  }
  test(
    'engine-specific levels, DNS types and single upstream are explicit',
    () {
      expect(SingBoxSettings.read('{}', null)['logLevel'], 'info');
      expect(
        SingBoxSettings.read('{"log":{"disabled":true}}', null)['logLevel'],
        'disabled',
      );
      expect(XraySettings.read('{}', null)['logLevel'], 'warning');
      expect(
        () => SingBoxSettings.prepare('{}', null, {
          'dnsMode': 'custom',
          'resolvers': '1.1.1.1\n9.9.9.9',
        }),
        throwsA(isA<ApiException>()),
      );
      expect(
        () => XraySettings.prepare('{}', null, {
          'dnsMode': 'custom',
          'resolvers': 'tls://one.one.one.one',
        }),
        throwsA(isA<ApiException>()),
      );
      expect(
        () => XraySettings.prepare('{}', null, {
          'dnsMode': 'custom',
          'resolvers': 'tcp://dns.example',
        }),
        throwsA(isA<ApiException>()),
      );
    },
  );
  test('Xray restores access/error log destinations after none', () {
    final base = <String, dynamic>{
      'log': {
        'access': 'access.log',
        'error': 'error.log',
        'loglevel': 'warning',
      },
      'inbounds': [],
      'outbounds': [],
    };
    final disabled = XraySettings.prepare(jsonEncode(base), null, {
      'logLevel': 'none',
    });
    XraySettings.apply(base, [], disabled);
    expect(base['log'], {
      'access': 'none',
      'error': 'none',
      'loglevel': 'none',
    });
    final enabled = XraySettings.prepare(jsonEncode(base), disabled, {
      'logLevel': 'info',
    });
    XraySettings.apply(base, [], enabled);
    expect(base['log'], {
      'access': 'access.log',
      'error': 'error.log',
      'loglevel': 'info',
    });
  });
  test('Xray detects scripts and foreign IP routing conflicts explicitly', () {
    for (final routing in [
      {'script': 'owner script'},
      {
        'domainStrategy': 'AsIs',
        'rules': [
          {
            'type': 'field',
            'ip': ['10.0.0.0/8'],
            'outboundTag': 'direct',
          },
        ],
      },
    ]) {
      final base = <String, dynamic>{
        'routing': routing,
        'inbounds': [
          {'tag': 'foreign'},
        ],
        'outbounds': [],
      };
      final values = XraySettings.prepare(jsonEncode(base), null, {
        'blockPrivate': 'true',
      });
      expect(
        () => XraySettings.apply(base, ['sky-owned'], values),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'core_settings_routing_conflict',
          ),
        ),
      );
    }
  });
}
