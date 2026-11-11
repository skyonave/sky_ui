import 'package:test/test.dart';
import 'package:sky_ui_ops/src/features/updates/release_catalog.dart'
    show releaseAssets, repository;
import 'package:sky_ui_ops/src/platform/host.dart';

import '../tool/draft_release.dart'
    show assetNames, checkBundledNodeInstaller, checkIdentity;

void main() {
  test(
    'release ships the same node installer separately and inside each bundle',
    () {
      expect(
        assetNames,
        containsAll([
          'install-server-node.sh',
          'install-server-node.sh.sha256',
        ]),
      );
      expect(() => checkBundledNodeInstaller([1, 2], [1, 2]), returnsNormally);
      for (final bundled in [
        null,
        <int>[],
        [1, 3],
      ]) {
        expect(
          () => checkBundledNodeInstaller(bundled, [1, 2]),
          throwsA(isA<OpsError>()),
        );
      }
    },
  );
  test(
    'panel updates select only the architecture bundle and panel installer',
    () {
      const tag = 'v1.2.0';
      final selected = releaseAssets({
        'tag_name': tag,
        'assets': [
          for (final name in assetNames)
            {
              'name': name,
              'state': 'uploaded',
              'size': 100,
              'digest': 'sha256:${'a' * 64}',
              'browser_download_url':
                  '$repository/releases/download/$tag/$name',
            },
        ],
      }, 'linux-amd64');
      expect(
        selected?.keys,
        unorderedEquals([
          'sky-ui-linux-amd64.tar.gz',
          'sky-ui-linux-amd64.tar.gz.sha256',
          'install.sh',
          'install.sh.sha256',
        ]),
      );
    },
  );
  const tag = 'v0.8.0-dev.1', commit = 'test-commit';
  Map<String, dynamic> fixture() => {
    'tag_name': tag,
    'target_commitish': commit,
    'draft': true,
  };
  test('draft identity uses the real tag', () {
    expect(() => checkIdentity(fixture(), tag, commit), returnsNormally);
  });
  for (final replacement in [
    {'tag_name': 'untagged-temporary', 'name': tag},
    {'target_commitish': 'main'},
    {'draft': false},
  ]) {
    test('reject draft identity mismatch $replacement', () {
      expect(
        () => checkIdentity({...fixture(), ...replacement}, tag, commit),
        throwsA(isA<OpsError>()),
      );
    });
  }
}
