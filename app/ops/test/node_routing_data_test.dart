import 'package:sky_ui_ops/src/features/servers/node_routing_data.dart';
import 'package:sky_ui_ops/src/platform/host.dart';
import 'package:test/test.dart';

void main() {
  const directory = '/var/lib/sky-ui-node/engines/xray/runtime';
  test('plain rules do not download unused geographic databases', () {
    for (final engine in ['mihomo', 'xray', 'sing-box', 'amneziawg']) {
      expect(nodeRoutingAssets(engine, {}, directory), isEmpty);
    }
    expect(
      nodeRoutingAssets('mihomo', {
        'rules': ['GEOIP,LAN,REJECT'],
      }, directory),
      isEmpty,
    );
  });
  test('Mihomo selects native formats for referenced groups only', () {
    final config = {
      'sub-rules': {
        'sky-ui/routing/fixture': ['GEOSITE,youtube,DIRECT', 'GEOIP,ru,REJECT'],
      },
    };
    final defaults = nodeRoutingAssets('mihomo', config, directory);
    expect(defaults.keys, [
      '$directory/GeoSite.dat',
      '$directory/geoip.metadb',
    ]);
    expect(
      defaults.values.first.toString(),
      'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat',
    );
    expect(
      nodeRoutingAssets('mihomo', {
        ...config,
        'geodata-mode': true,
      }, directory).keys,
      ['$directory/GeoSite.dat', '$directory/GeoIP.dat'],
    );
  });
  test('Xray only provisions generated renamed dat files', () {
    final files = nodeRoutingAssets('xray', {
      'routing': {
        'rules': [
          {
            'domain': ['ext:sky-ui-geosite.dat:youtube'],
          },
          {
            'ip': ['ext:sky-ui-geoip.dat:ru'],
          },
          {
            'domain': ['ext:arbitrary.dat:test'],
          },
        ],
      },
    }, directory);
    expect(files.keys, [
      '$directory/sky-ui-geosite.dat',
      '$directory/sky-ui-geoip.dat',
    ]);
    expect(
      files.values.last.toString(),
      'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat',
    );
  });
  test(
    'sing-box requires exact generated tag, format and destination path',
    () {
      Map<String, dynamic> config(
        String path, {
        String tag = 'sky-ui/routing/geosite/youtube',
      }) => {
        'route': {
          'rule_set': [
            {'type': 'local', 'format': 'binary', 'tag': tag, 'path': path},
          ],
        },
      };
      final expected = '$directory/sky-ui-geosite-youtube.srs';
      final files = nodeRoutingAssets('sing-box', config(expected), directory);
      expect(files.keys, [expected]);
      expect(
        files.values.single.toString(),
        'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/youtube.srs',
      );
      expect(
        () => nodeRoutingAssets('sing-box', config('/etc/passwd'), directory),
        throwsA(isA<OpsError>()),
      );
      expect(
        nodeRoutingAssets(
          'sing-box',
          config(expected, tag: 'sky-ui/routing/geosite/../../passwd'),
          directory,
        ),
        isEmpty,
      );
    },
  );
}
