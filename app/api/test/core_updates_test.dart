import 'package:sky_ui_api/src/core_updates.dart';
import 'package:sky_ui_api/src/errors.dart';
import 'package:test/test.dart';

Map<String, dynamic> release(
  String version, {
  bool verified = true,
  String panel = 'fixture-panel',
  bool platformVerified = true,
}) => {
  'version': version,
  'verified': verified,
  'panelVersions': [panel],
  'platforms': {
    'linux-amd64': {
      'verified': platformVerified,
      'asset': 'mihomo-linux-amd64-v1-$version.gz',
      'sha256': 'a' * 64,
    },
  },
};
Map<String, dynamic> catalog(List<Map<String, dynamic>> releases) => {
  'schemaVersion': 1,
  'coreId': 'mihomo',
  'releases': releases,
};

void main() {
  CoreUpdates service(Map<String, dynamic> value) => CoreUpdates(
    platform: 'linux-amd64',
    panelVersion: 'fixture-panel',
    fetch: (uri) async {
      expect(uri.toString(), '${CoreUpdates.base}/mihomo.json');
      return value;
    },
  );
  test(
    'only approved newer versions for this panel and platform are offered',
    () async {
      final updates = service(
        catalog([
          release('v1.19.33'),
          release('v1.19.34'),
          release('v1.20.0', verified: false),
          release('v1.21.0', panel: 'another-panel'),
          release('v1.22.0', platformVerified: false),
        ]),
      );
      expect((await updates.get('mihomo', 'v1.19.33')).versions, ['v1.19.34']);
      expect((await updates.get('mihomo', 'v1.19.34')).available, false);
      expect((await updates.get('mihomo', null)).available, false);
    },
  );
  test('bad identities, hashes and duplicate versions fail closed', () async {
    final badHash = release('v1.20.0');
    (badHash['platforms'] as Map)['linux-amd64']['sha256'] = 'invalid';
    for (final value in [
      catalog([badHash]),
      {...catalog([]), 'coreId': 'xray'},
      catalog([release('v1.20.0'), release('v1.20.0')]),
    ]) {
      await expectLater(
        service(value).get('mihomo', 'v1.19.33'),
        throwsA(isA<ApiException>()),
      );
    }
  });
  test(
    'approval is fetched again before submission and revoked releases are rejected',
    () async {
      var calls = 0;
      final updates = CoreUpdates(
        platform: 'linux-amd64',
        panelVersion: 'fixture-panel',
        fetch: (_) async =>
            catalog([release('v1.20.0', verified: ++calls == 1)]),
      );
      expect((await updates.get('mihomo', 'v1.19.33')).available, true);
      await expectLater(
        updates.requireApproved('mihomo', 'v1.20.0'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'core_release_unverified',
          ),
        ),
      );
      expect(calls, 2);
    },
  );
  test(
    'a failed catalog never falls back to an upstream release feed',
    () async {
      var calls = 0;
      final updates = CoreUpdates(
        fetch: (uri) async {
          calls++;
          throw StateError('offline');
        },
      );
      await expectLater(
        updates.get('mihomo', 'v1.19.33'),
        throwsA(isA<ApiException>()),
      );
      expect(calls, 1);
    },
  );
}
