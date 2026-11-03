import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sky_ui_ops/src/host.dart';
import 'package:sky_ui_ops/src/archives.dart';
import 'package:sky_ui_ops/src/releases.dart';

Future<void> main(List<String> args) async {
  require(
    args.length == 3 && args[0].contains('protocol-first'),
    'Pass private fixture, native bundle and installer.',
  );
  final root = args[0], indexFile = File('${args[0]}/http-index.json');
  final index = object(jsonDecode(indexFile.readAsStringSync()));
  final files = tarFiles(
    File(args[1]).readAsBytesSync(),
    limit: 256 * 1024 * 1024,
    maxFiles: 20000,
    directories: true,
  );
  final installer = File(args[2]).readAsStringSync();
  Uint8List bytes(String s) => Uint8List.fromList(utf8.encode(s));
  void cache(String url, List<int> body) {
    final name = digest(utf8.encode(url));
    File('$root/http/$name').writeAsBytesSync(body);
    index[url] = {'name': name, 'sha256': digest(body)};
  }

  final feedRows = <Map<String, dynamic>>[];
  for (final version in ['0.8.0-dev.4', '0.8.0-dev.5', '0.8.0-dev.6']) {
    final tag = 'v$version', copy = {...files};
    copy['VERSION'] = bytes('$version\n');
    copy['SOURCE_SHA256'] = bytes(
      '${digest(bytes('isolated native fixture $version'))}\n',
    );
    if (version.endsWith('.5'))
      copy['bin/sky-ui'] = bytes(
        '#!/bin/sh\nif [ "\$1" = --version ]; then echo "Sky UI $version"; else exit 23; fi\n',
      );
    var script = installer;
    if (version.endsWith('.6'))
      script = script.replaceFirst('set -Eeuo pipefail', '''set -Eeuo pipefail
if [[ " \$* " != *" --prepare-only "* ]]; then
  touch /var/lib/sky-ui-maintenance/interruption-marker
  sleep 120
fi''');
    final assets = <String, List<int>>{
      'sky-ui-linux-amd64.tar.gz': packTar(copy),
      'install.sh': bytes(script),
    };
    for (final entry in assets.entries.toList())
      assets['${entry.key}.sha256'] = bytes(
        '${digest(entry.value)}  ${entry.key}\n',
      );
    final rows = <Map<String, dynamic>>[];
    for (final entry in assets.entries) {
      final url = '$repository/releases/download/$tag/${entry.key}';
      cache(url, entry.value);
      rows.add({
        'name': entry.key,
        'state': 'uploaded',
        'size': entry.value.length,
        'digest': 'sha256:${digest(entry.value)}',
        'browser_download_url': url,
      });
    }
    feedRows.add({
      'tag_name': tag,
      'draft': false,
      'prerelease': true,
      'assets': rows,
    });
  }
  cache(feed, bytes(jsonEncode(feedRows)));
  indexFile.writeAsStringSync(jsonEncode(index));
  stdout.writeln('Prepared three checked offline update fixtures.');
}
