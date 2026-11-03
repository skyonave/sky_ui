import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../tool/native_manifest.dart' show elfMatches, sourceInput;
import '../tool/native_manifest.dart' as manifest;

void main() {
  test(
    'refreshing native metadata preserves its identity and file inventory',
    () {
      final payload = Directory.systemTemp.createTempSync('sky-ui-manifest-');
      addTearDown(() => payload.deleteSync(recursive: true));
      File('${payload.path}/VERSION').writeAsStringSync('test\n');
      final sources = {'VERSION': 'a' * 64};
      manifest.writeManifest(payload.path, sources, 'amd64');
      final first = File('${payload.path}/BUILD_MANIFEST.json')
          .readAsStringSync();
      final identity = File('${payload.path}/SOURCE_SHA256').readAsStringSync();
      manifest.writeManifest(payload.path, sources, 'amd64');
      expect(
        File('${payload.path}/BUILD_MANIFEST.json').readAsStringSync(),
        first,
      );
      expect(
        File('${payload.path}/SOURCE_SHA256').readAsStringSync(),
        identity,
      );
    },
  );
  test(
    'source identity excludes retired Python caches and compiled local outputs',
    () {
      expect(sourceInput('deploy/__pycache__/legacy.cpython-312.pyc'), isFalse);
      expect(sourceInput('app/api/bin/server.exe'), isFalse);
      expect(sourceInput('app/ops/lib/src/cli/commands.dart'), isTrue);
      expect(sourceInput('deploy/skyui'), isTrue);
      expect(sourceInput('app/web/web/fonts/PxPlus_IBM_VGA8.ttf'), isTrue);
    },
  );
  Uint8List header(int machine) => Uint8List(64)
    ..setRange(0, 6, [0x7f, 69, 76, 70, 2, 1])
    ..[18] = machine;
  test('native release rejects a substituted architecture or ELF class', () {
    expect(elfMatches(header(62), 'amd64'), isTrue);
    expect(elfMatches(header(183), 'arm64'), isTrue);
    expect(elfMatches(header(62), 'arm64'), isFalse);
    expect(elfMatches(header(183), 'amd64'), isFalse);
    expect(elfMatches(header(62)..[4] = 1, 'amd64'), isFalse);
    expect(elfMatches(header(62)..[5] = 2, 'amd64'), isFalse);
    expect(elfMatches(Uint8List(4), 'amd64'), isFalse);
  });
}
