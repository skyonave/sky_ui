import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_api/src/application/configuration/route_policy.dart';
import 'package:sky_ui_api/src/engines/managed_core.dart';
import 'package:sky_ui_api/src/engines/mihomo/adapter.dart';
import 'package:sky_ui_api/src/engines/mihomo/routing.dart';
import 'package:sky_ui_api/src/engines/proxy/routing_geodata.dart';
import 'package:sky_ui_api/src/engines/sing_box/settings.dart';
import 'package:sky_ui_api/src/engines/xray/settings.dart';
import 'package:sky_ui_api/src/infrastructure/process/command_runner.dart';
import 'package:sky_ui_api/src/shared/api_exception.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';

const _local = Connection.localNode;
const _block = NodeRouting.block;
const _rules = [
  RoutingRule('domain', ' Example.org, example.org, EXAMPLE.NET. ', _block),
  RoutingRule('wildcard', '*.example.com', _block),
  RoutingRule('keyword', 'ads', _block),
  RoutingRule('geosite', 'geosite:YouTube', _block),
  RoutingRule('geoip', 'RU', _block),
  RoutingRule('cidr', '192.0.2.1\n2001:db8::1', _block),
  RoutingRule('port', '80, 443', _block),
];

Connection _connection(String engine, List<RoutingRule> rules) => Connection(
  id: 'fixture',
  name: 'Routing fixture',
  coreId: engine,
  protocolId: 'vless',
  port: 8443,
  routing: {_local: NodeRouting(rules: rules)},
);

void main() {
  test(
    'normalizes ordered rules and rejects invalid or unsupported targets',
    () {
      final policy = RoutePolicy.validate(
        _connection('mihomo', _rules),
      )[_local]!;
      expect(policy.rules.first.targets, ['example.org', 'example.net']);
      expect(policy.rules[3].target, 'youtube');
      expect(policy.rules[4].target, 'ru');
      expect(policy.rules[5].targets, ['192.0.2.1/32', '2001:db8::1/128']);
      expect(MihomoRouting.rules(policy, 'DIRECT', [], 'fixture'), [
        'DOMAIN,example.org,REJECT',
        'DOMAIN,example.net,REJECT',
        r'DOMAIN-REGEX,^[a-z0-9.-]*\.example\.com$,REJECT',
        'DOMAIN-KEYWORD,ads,REJECT',
        'GEOSITE,youtube,REJECT',
        'GEOIP,ru,REJECT',
        'IP-CIDR,192.0.2.1/32,REJECT',
        'IP-CIDR6,2001:db8::1/128,REJECT',
        'DST-PORT,80,REJECT',
        'DST-PORT,443,REJECT',
        'MATCH,DIRECT',
      ]);
      final invalid = throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'route_policy_invalid',
        ),
      );
      for (final rule in [
        const RoutingRule('geosite', '../youtube', _block),
        const RoutingRule('wildcard', '(.*).example.com', _block),
        const RoutingRule('cidr', '192.0.2.1, invalid', _block),
        const RoutingRule('network', 'tcp, udp', _block),
        RoutingRule('port', List.filled(9, '443').join(','), _block),
      ]) {
        expect(
          () => RoutePolicy.validate(_connection('xray', [rule])),
          invalid,
        );
      }
      expect(
        () => RoutePolicy.validate(_connection('amneziawg', [_rules[3]])),
        invalid,
      );
    },
  );

  final data = Platform.environment['SKY_UI_ROUTING_GEODATA_DIRECTORY'];
  final fetch = Platform.environment['SKY_UI_ROUTING_GEODATA_FETCH'] == '1';
  for (final (engine, variable) in [
    ('mihomo', 'SKY_UI_MIHOMO_BINARY'),
    ('sing-box', 'SKY_UI_SING_BOX_BINARY'),
    ('xray', 'SKY_UI_XRAY_BINARY'),
  ]) {
    final binary = Platform.environment[variable];
    test(
      'native $engine validates expanded routing matches',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'sky-routing-matches-',
        );
        try {
          final policy = RoutePolicy.validate(
            _connection(engine, _rules),
          )[_local]!;
          final files = switch (engine) {
            'mihomo' => {
              'sky-ui-geosite.dat': 'GeoSite.dat',
              'sky-ui-geoip.dat': 'GeoIP.dat',
            },
            'xray' => {
              'sky-ui-geosite.dat': 'sky-ui-geosite.dat',
              'sky-ui-geoip.dat': 'sky-ui-geoip.dat',
            },
            _ => {
              'sky-ui-geosite-youtube.srs': 'sky-ui-geosite-youtube.srs',
              'sky-ui-geoip-ru.srs': 'sky-ui-geoip-ru.srs',
            },
          };
          if (!fetch) {
            for (final entry in files.entries) {
              await File(
                '$data/${entry.key}',
              ).copy('${root.path}/${entry.value}');
            }
          }
          final config = File('${root.path}/config.json');
          final native = _native(engine, root.path, policy);
          if (fetch && engine == 'mihomo') native.remove('geodata-mode');
          await config.writeAsString(jsonEncode(native));
          if (fetch) {
            final core = ManagedCore(
              id: engine,
              coreId: engine,
              service: 'fixture',
              binary: binary!,
              directory: root.path,
              configuration: config.path,
              controller: Uri.parse('http://127.0.0.1:0'),
              secret: '',
            );
            const runner = NativeCommandRunner();
            if (engine == 'mihomo') {
              await MihomoAdapter(runner).validate(core);
            } else {
              await RoutingGeoData.prepare(core, native, runner);
              for (final name in files.values) {
                final asset = File('${root.path}/$name');
                expect(await asset.length(), greaterThan(0));
                if (Platform.isLinux) {
                  expect((await asset.stat()).mode & 0x1ff, 0x1a0);
                }
              }
            }
          }
          final args = switch (engine) {
            'mihomo' => ['-t', '-d', root.path, '-f', config.path],
            'xray' => ['run', '-test', '-config', config.path],
            _ => ['check', '-c', config.path],
          };
          final check = await Process.run(
            binary!,
            args,
            environment: {
              if (engine == 'xray') 'XRAY_LOCATION_ASSET': root.path,
            },
          );
          expect(check.exitCode, 0, reason: '${check.stdout}\n${check.stderr}');
        } finally {
          await root.delete(recursive: true);
        }
      },
      skip: binary == null || (data == null && !fetch)
          ? 'Set the verified native binary and a routing dataset source.'
          : false,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}

Map<String, dynamic> _native(
  String engine,
  String directory,
  NodeRouting policy,
) {
  const tag = 'sky-fixture';
  if (engine == 'mihomo') {
    return {
      'mode': 'rule',
      'geodata-mode': true,
      'sub-rules': {tag: MihomoRouting.rules(policy, 'DIRECT', [], 'fixture')},
      'listeners': [
        {'name': tag, 'type': 'socks', 'port': 8443, 'rule': tag},
      ],
    };
  }
  final xray = engine == 'xray';
  final base = <String, dynamic>{
    'inbounds': [
      if (xray)
        {'tag': tag, 'port': 8443, 'protocol': 'socks'}
      else
        {'tag': tag, 'listen_port': 8443, 'type': 'socks'},
    ],
    'outbounds': [
      if (xray)
        {'tag': 'direct', 'protocol': 'freedom'}
      else
        {'tag': 'direct', 'type': 'direct'},
    ],
  };
  if (xray) {
    XraySettings.apply(
      base,
      [tag],
      XraySettings.prepare('{}', null, {}),
      policies: {tag: policy},
    );
  } else {
    SingBoxSettings.apply(
      base,
      [tag],
      SingBoxSettings.prepare('{}', null, {}),
      policies: {tag: policy},
      directory: directory,
    );
  }
  return base;
}
