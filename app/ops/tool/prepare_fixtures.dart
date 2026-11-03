import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sky_ui_ops/src/platform/host.dart';
import 'package:sky_ui_ops/src/shared/artifacts.dart';
import 'package:sky_ui_ops/src/features/engines/installer.dart';
import 'package:sky_ui_ops/src/shared/archives.dart';

Future<void> main(List<String> args) async {
  require(
    args.length == 1 || args.length == 2 && args[1] == '--rebuild-awg',
    'Pass a private protocol-first fixture directory.',
  );
  final root = Directory(args.first).absolute.path,
      project = Directory.fromUri(Platform.script.resolve('../../../')).path;
  require(root.contains('protocol-first'), 'private_fixture_required');
  Directory(root).createSync(recursive: true);
  final version = File('$project/VERSION').readAsStringSync().trim();
  Directory('$root/http').createSync();
  final indexFile = File('$root/http-index.json');
  final index = indexFile.existsSync()
      ? object(jsonDecode(indexFile.readAsStringSync()))
      : <String, dynamic>{};
  Future<Uint8List> cached(String url, int limit) async {
    final name = digest(utf8.encode(url)), path = '$root/http/$name';
    final result = File(path).existsSync()
        ? await File(path).readAsBytes()
        : await httpBytes(url, limit);
    require(result.length <= limit, 'fixture_too_large');
    File(path).writeAsBytesSync(result);
    index[url] = {'name': name, 'sha256': digest(result)};
    indexFile.writeAsStringSync(jsonEncode(index));
    return result;
  }

  Future<Uint8List> catalog(String url, int limit) async {
    require(
      url.startsWith('$catalogBase/') &&
          engineIds.any((c) => url == '$catalogBase/$c.json'),
      'fixture_catalog_invalid',
    );
    final result = await File(
      '$project/compatibility/cores/${Uri.parse(url).pathSegments.last}',
    ).readAsBytes();
    final name = digest(utf8.encode(url));
    File('$root/http/$name').writeAsBytesSync(result);
    index[url] = {'name': name, 'sha256': digest(result)};
    indexFile.writeAsStringSync(jsonEncode(index));
    return result;
  }

  for (final core in engineIds) {
    final selected = await verifiedRelease(
          core,
          version,
          targetPlatform(),
          fetch: catalog,
        ),
        receiptFile = File('$root/$core.artifact.json');
    if (!(core == 'amneziawg' && args.contains('--rebuild-awg')) &&
        File('$root/$core').existsSync() &&
        receiptFile.existsSync()) {
      final receipt = object(jsonDecode(receiptFile.readAsStringSync()));
      if (receipt['archiveSha256'] == selected.sha &&
          receipt['version'] == selected.tag &&
          receipt['binarySha256'] ==
              digest(File('$root/$core').readAsBytesSync())) {
        stdout.writeln('$core: retained verified fixture.');
        continue;
      }
    }
    final files = await artifactFiles(
      core,
      selected.tag,
      selected.url,
      selected.sha,
      targetPlatform(),
      fetch: cached,
    );
    if (core == 'sing-box') {
      final entries = tarSelected(
        await cached(selected.url, 128 * 1024 * 1024),
        (name) => name.endsWith('/libcronet.so'),
        limit: 256 * 1024 * 1024,
        maxFiles: 8192,
      );
      File('$root/libcronet.so').writeAsBytesSync(
        entries.entries
            .singleWhere((e) => e.key.endsWith('/libcronet.so'))
            .value,
      );
    }
    if (core == 'amneziawg') {
      require(
        host.uid() == 0,
        'Linux root is required for the isolated AWG build account.',
      );
      files[core] = await temporary(
        '/var/tmp',
        'sky-ui-fixture-build-',
        (work) =>
            buildAwg(files.remove('source.tar.gz')!, work, selected.tag, null),
      );
      final receipt = object(jsonDecode(utf8.decode(files['artifact.json']!)));
      receipt['binarySha256'] = digest(files[core]!);
      files['artifact.json'] = Uint8List.fromList(
        utf8.encode(jsonEncode(receipt)),
      );
    }
    File('$root/$core').writeAsBytesSync(files[core]!);
    await run(['chmod', '0755', '$root/$core']);
    File('$root/$core.LICENSE').writeAsBytesSync(files['LICENSE']!);
    receiptFile.writeAsBytesSync(files['artifact.json']!);
    stdout.writeln('$core: verified fixture ready.');
  }
  await run([
    'openssl',
    'req',
    '-x509',
    '-newkey',
    'ec',
    '-pkeyopt',
    'ec_paramgen_curve:P-256',
    '-nodes',
    '-days',
    '2',
    '-subj',
    '/CN=localhost',
    '-addext',
    'subjectAltName=DNS:localhost,IP:127.0.0.1',
    '-keyout',
    '$root/key.pem',
    '-out',
    '$root/cert.pem',
  ]);
  final generator = await Process.start(
    Platform.resolvedExecutable,
    ['run', 'tool/fleet_fixtures.dart', root],
    workingDirectory: '$project/app/api',
    mode: ProcessStartMode.inheritStdio,
  );
  require(await generator.exitCode == 0, 'fixture_generation_failed');
}
