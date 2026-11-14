import 'package:sky_ui_api/src/infrastructure/process/node_bootstrap_catalog.dart';
import 'package:sky_ui_api/src/shared/api_exception.dart';
import 'package:test/test.dart';

Map<String, Object?> release(
  String version, {
  String panel = '2.0.0',
  bool verified = true,
  bool arm = true,
}) => {
  'version': version,
  'verified': verified,
  'panelVersions': [panel],
  'platforms': {
    for (final arch in ['amd64', if (arm) 'arm64'])
      'linux-$arch': {
        'verified': true,
        'asset': 'mihomo-linux-$arch-$version.gz',
        'sha256': 'a' * 64,
      },
  },
};

void main() {
  Map<String, dynamic> catalog(List<Map<String, Object?>> releases) => {
    'schemaVersion': 1,
    'coreId': 'mihomo',
    'releases': releases,
  };
  test(
    'selects newest exact-panel approved version independently per architecture',
    () {
      final chosen = selectNodeBootstrapAssets(
        catalog([
          release('v1.9.0'),
          release('v9.0.0', panel: 'future'),
          release('v2.0.0', verified: false),
          release('v1.10.0', arm: false),
        ]),
        '2.0.0',
      );
      expect(chosen['x86_64']!.version, 'v1.10.0');
      expect(chosen['aarch64']!.version, 'v1.9.0');
      expect(chosen['x86_64']!.sha256, 'a' * 64);
    },
  );
  test(
    'does not install a merely verified release approved for another panel',
    () {
      expect(
        selectNodeBootstrapAssets(
          catalog([release('v1.10.0', panel: '1.5.0')]),
          '2.0.0',
        ),
        isEmpty,
      );
    },
  );
  test('rejects wrong catalog identity and unsafe download names', () {
    expect(
      () => selectNodeBootstrapAssets({
        'schemaVersion': 1,
        'coreId': 'xray',
        'releases': [],
      }, '2.0.0'),
      throwsA(isA<ApiException>()),
    );
    final bad = release('v1.10.0');
    bad['platforms'] = {
      'linux-amd64': {
        'verified': true,
        'asset': "bad';touch pwn.gz",
        'sha256': 'a' * 64,
      },
    };
    expect(selectNodeBootstrapAssets(catalog([bad]), '2.0.0'), isEmpty);
  });
}
