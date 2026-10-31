import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final destination = Directory(args.last)..createSync(recursive: true);
  for (final project in args.take(args.length - 1)) {
    final config = File('$project/.dart_tool/package_config.json');
    final packages =
        (jsonDecode(config.readAsStringSync()) as Map)['packages'] as List;
    for (final package in packages.cast<Map>()) {
      final name = package['name'] as String;
      if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(name))
        throw FormatException('Invalid package name.');
      if (name.startsWith('sky_ui_')) continue;
      final root = Directory.fromUri(config.uri.resolve(package['rootUri'] as String)).uri;
      for (final candidate in [
        'LICENSE',
        'LICENSE.txt',
        'LICENSE.md',
        'COPYING',
      ]) {
        final license = File.fromUri(root.resolve(candidate));
        if (license.existsSync()) {
          license.copySync('${destination.path}/$name.txt');
          break;
        }
      }
    }
  }
}
