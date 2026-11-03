import 'package:test/test.dart';
import 'package:sky_ui_ops/src/platform/host.dart';

import '../tool/draft_release.dart' show checkIdentity;

void main() {
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
