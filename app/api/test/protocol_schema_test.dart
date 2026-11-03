import 'dart:convert';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/engines/mihomo/schema.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';
import '../../web/lib/src/shared/localization/strings.dart';

void main() {
  test(
    'V2Ray base64 keeps REALITY credentials and rejects incomplete exports',
    () {
      final exporter = V2RayExporter();
      const endpoint = ClientEndpoint(
        id: 'vless',
        name: 'Для iPhone',
        server: 'panel.example.test',
        port: 8443,
        protocolId: 'vless',
        settings: {
          'transport': 'TCP',
          'security': 'REALITY',
          'serverName': 'www.example.com',
          'flow': 'xtls-rprx-vision',
        },
        credentials: {
          'uuid': '0383573b-c576-425c-aa76-5951e944c22a',
          'publicKey': 'fixture-public-key',
          'shortId': '0123456789abcdef',
        },
      );
      final content = utf8
          .decode(base64.decode(exporter.profile([endpoint])))
          .trim();
      final uri = Uri.parse(content);
      expect(uri.scheme, 'vless');
      expect(uri.host, endpoint.server);
      expect(uri.port, endpoint.port);
      expect(uri.userInfo, endpoint.credentials['uuid']);
      expect(uri.queryParameters, containsPair('pbk', 'fixture-public-key'));
      expect(uri.queryParameters, containsPair('sid', '0123456789abcdef'));
      expect(uri.queryParameters, containsPair('flow', 'xtls-rprx-vision'));
      expect(Uri.decodeComponent(uri.fragment), endpoint.name);
      const unsupported = ClientEndpoint(
        id: 'snell',
        name: 'Other',
        server: 'panel.example.test',
        port: 8444,
        protocolId: 'snell',
        settings: {'transport': 'TCP', 'security': 'Built-in'},
        credentials: {'password': 'fixture'},
      );
      expect(exporter.canExport([endpoint, unsupported]), isFalse);
      expect(
        () => exporter.profile([endpoint, unsupported]),
        throwsA(isA<ApiException>()),
      );
      expect(exporter.canExport([]), isFalse);
      final shared = RecipientShare(
        subscriptionUrl: 'https://example.test/a.yaml',
        links: [],
        subscriptionUrls: {'v2ray': 'https://example.test/a.txt'},
      );
      expect(
        RecipientShare.fromJson(shared.toJson()).subscriptionUrls,
        shared.subscriptionUrls,
      );
      expect(
        RecipientShare.fromJson({
          'subscriptionUrl': 'https://example.test/a.yaml',
          'links': [],
        }).subscriptionUrls,
        isEmpty,
      );
    },
  );
  test('share URIs never discard required advanced client settings', () {
    final exporter = ClashExporter();
    ClientEndpoint endpoint(Map<String, String> extra) => ClientEndpoint(
      id: 'fixture',
      name: 'Fixture',
      server: 'panel.example.test',
      port: 33443,
      protocolId: 'vless',
      settings: {'transport': 'TCP', 'security': 'TLS', ...extra},
      credentials: {'uuid': '0383573b-c576-425c-aa76-5951e944c22a'},
    );
    expect(exporter.links([endpoint({})]), hasLength(1));
    final customAlpn = endpoint({'clientAlpn': 'h2'});
    expect(
      Uri.parse(
        exporter.links([customAlpn]).single.uri,
      ).queryParameters['alpn'],
      'h2',
    );
    final profile = jsonDecode(exporter.profile([customAlpn])) as Map;
    expect((profile['proxies'] as List).single['alpn'], ['h2']);
  });
  test(
    'stored incompatible options fail instead of silently changing a live client profile',
    () {
      final codec = MihomoConfiguration();
      expect(
        () => codec.clientEndpoint(
          const StoredConnection(
            Connection(
              id: 'stored',
              name: 'Stored',
              coreId: 'mihomo',
              protocolId: 'vless',
              port: 33443,
              settings: {'transport': 'not-a-transport'},
            ),
            {},
          ),
          const AccessGrant(
            id: 'grant',
            recipientId: 'person',
            connectionId: 'stored',
            credentials: {},
          ),
          '127.0.0.1',
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.fields['transport'],
            'transport',
            'choice_invalid',
          ),
        ),
      );
    },
  );
  final schema = MihomoSchemas(publicAddress: 'panel.example.test');
  test(
    'pinned inventory retains every public and system protocol with explicit OS requirements',
    () {
      final protocols = schema.protocols;
      expect(protocols.length, 21);
      expect(protocols.where((p) => !p.available).map((p) => p.id).toSet(), {
        'tun',
        'tproxy',
        'redirect',
      });
      expect(
        protocols.where((p) => p.isolatedBindings).map((p) => p.id).toSet(),
        {'shadowsocks', 'snell', 'sudoku'},
      );
      expect(
        protocols
            .where((p) => !p.shareable)
            .every((p) => p.category == 'system'),
        isTrue,
      );
    },
  );
  test(
    'dependent transport/security choices survive the API JSON boundary',
    () {
      final original = schema.definition('vless');
      final restored = ProtocolDefinition.fromJson(
        jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
      );
      final values = restored.defaults({
        'transport': 'WebSocket',
        'security': 'REALITY',
      });
      expect(values['security'], 'TLS');
      expect(
        restored.fields
            .firstWhere((f) => f.id == 'security')
            .allowedOptions(values),
        isNot(contains('REALITY')),
      );
      final vless = schema.definition('vless');
      expect(
        vless.fields
            .firstWhere((f) => f.id == 'flow')
            .visible(vless.defaults({'transport': 'WebSocket'})),
        isFalse,
      );
    },
  );
  test(
    'managed certificate SNI is derived from a stable alias, not its identifier',
    () {
      final managed = MihomoSchemas(
        certificateIds: ['panel', 'panel.example.test'],
        certificateHosts: {
          'panel': 'panel.example.test',
          'panel.example.test': 'panel.example.test',
        },
      );
      final p = managed.definition('trojan');
      final parsed = ProtocolDefinition.fromJson(
        jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>,
      );
      final values = parsed.defaults();
      expect(values['certificateSource'], 'panel');
      expect(values['serverName'], 'panel.example.test');
      expect(
        parsed.fields.firstWhere((f) => f.id == 'serverName').derived(values),
        isTrue,
      );
    },
  );
  test(
    'structured dictionaries reject duplicates and malformed numeric lists',
    () {
      const table = ProtocolField(
        'map',
        kind: 'rows',
        rowKeyField: 'key',
        children: [
          ProtocolField('key', required: true),
          ProtocolField('value'),
        ],
      );
      expect(
        table.validate(
          '[{"key":"same","value":"a"},{"key":"same","value":"b"}]',
          {},
        ),
        'rows_invalid',
      );
      expect(table.validate('[{"key":12,"value":"a"}]', {}), 'rows_invalid');
      const numbers = ProtocolField(
        'numbers',
        kind: 'lines',
        itemKind: 'integer',
        minimum: 0,
      );
      expect(numbers.validate('1\ninvalid', {}), 'integer_invalid');
      expect(numbers.validate('-1', {}), 'range_invalid');
    },
  );
  test(
    'every exposed native field has localized context, including nested rows',
    () {
      const t = AppStrings();
      final missing = <String>{};
      void check(ProtocolField field) {
        if (t(field.labelKey) == field.labelKey) missing.add(field.labelKey);
        if (t(field.helpKey) == field.helpKey) missing.add(field.helpKey);
        for (final child in field.children) check(child);
      }

      for (final protocol in schema.protocols)
        for (final field in protocol.fields) check(field);
      expect(missing, isEmpty);
    },
  );
  test(
    'invalid TLS pairs are rejected before recipients or core activation',
    () {
      final codec = MihomoConfiguration(publicAddress: 'panel.example.test');
      expect(
        () => codec.validateSettings(
          const Connection(
            id: 'test',
            name: 'test',
            coreId: 'mihomo',
            protocolId: 'trojan',
            port: 33443,
            settings: {'tlsCertificate': 'invalid', 'tlsPrivateKey': 'invalid'},
          ),
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.fields['tlsPrivateKey'],
            'private key field',
            'certificate_invalid',
          ),
        ),
      );
    },
  );
}
