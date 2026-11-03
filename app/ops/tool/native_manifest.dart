import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_ops/src/host.dart' show digest, require;

bool sourceInput(String path) {
  final name = path.replaceAll('\\', '/').split('/').last;
  return ['skyui', 'sky-ui'].contains(name) ||
      RegExp(
        r'\.(dart|json|yaml|yml|c|h|sh|conf|rules|service|timer|md|html|css|ttf|txt)$',
      ).hasMatch(name);
}

String sourceHash(File file) {
  final data = file.readAsBytesSync();
  return digest(
    file.path.endsWith('.ttf')
        ? data
        : utf8.encode(utf8.decode(data).replaceAll('\r\n', '\n')),
  );
}

Map<String, String> buildSources(String root) {
  final paths = <String>{
    'VERSION',
    'LICENSE',
    'install.sh',
    'tool/build_release.sh',
    'tool/build_release_environment.sh',
    'app/web/FEATHER-LICENSE.txt',
    'app/ops/tool/native_manifest.dart',
    for (final package in ['api', 'ops', 'web']) ...[
      'app/$package/pubspec.yaml',
      'app/$package/pubspec.lock',
    ],
    'app/shared/pubspec.yaml',
  };
  for (final directory in [
    'deploy',
    'compatibility',
    'tool/release',
    'app/api/lib',
    'app/api/bin',
    'app/ops/lib',
    'app/ops/bin',
    'app/ops/native',
    'app/shared/lib',
    'app/web/lib',
    'app/web/web',
  ]) {
    for (final file in Directory(
      '$root/$directory',
    ).listSync(recursive: true, followLinks: false)) {
      require(file is! Link, 'build_source_link');
      if (file is File && sourceInput(file.path))
        paths.add(file.path.substring(root.length + 1).replaceAll('\\', '/'));
    }
  }
  return {
    for (final path in paths.toList()..sort())
      path: sourceHash(File('$root/$path')),
  };
}

bool elfMatches(List<int> bytes, String arch) =>
    bytes.length >= 20 &&
    bytes[0] == 0x7f &&
    bytes[1] == 69 &&
    bytes[2] == 76 &&
    bytes[3] == 70 &&
    bytes[4] == 2 &&
    bytes[5] == 1 &&
    bytes[18] + (bytes[19] << 8) == (arch == 'amd64' ? 62 : 183);

void main(List<String> args) {
  require(
    args.length == 3,
    'Pass project root, audited payload and architecture.',
  );
  final root = Directory(args[0]).absolute.path,
      payload = Directory(args[1]).absolute.path,
      arch = args[2];
  require(['amd64', 'arm64'].contains(arch), 'unsupported_architecture');
  writeManifest(payload, buildSources(root), arch);
}

void writeManifest(String payload, Map<String, String> sources, String arch) {
  final names =
      Directory(payload)
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .map((f) => f.path.substring(payload.length + 1))
          .where(
            (name) => !['SOURCE_SHA256', 'BUILD_MANIFEST.json'].contains(name),
          )
          .toList()
        ..sort();
  final files = {
    for (final name in names)
      name: digest(File('$payload/$name').readAsBytesSync()),
  };
  final identity = digest(utf8.encode(jsonEncode(sources)));
  File('$payload/SOURCE_SHA256').writeAsStringSync('$identity\n');
  File('$payload/BUILD_MANIFEST.json').writeAsStringSync(
    jsonEncode({
      'format': 'native-v1',
      'architecture': arch,
      'glibc': '2.31',
      'sources': sources,
      'files': files,
    }),
  );
}
