import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sky_ui_ops/src/archives.dart';
import 'package:sky_ui_ops/src/host.dart';

// Reintroduce only the historical cwd bug in a private source fixture, to prove
// a failed SDK probe retains a verified download for the corrected installer.
void main(List<String> args) {
  require(
    args.length == 2,
    'Pass checked source bundle and private destination.',
  );
  final directory = Directory(args[1]).absolute.path;
  require(
    directory.startsWith('/root/sky-ui-test/install-repair/'),
    'private_fixture_required',
  );
  final files = tarFiles(
    File(args[0]).readAsBytesSync(),
    limit: 256 * 1024 * 1024,
    maxFiles: 20000,
    directories: true,
  );
  const member = 'deploy/dart_sdk.sh';
  final original = utf8.decode(files[member]!);
  require(
    original.contains('  cd -- "\$work/source"'),
    'fixture_cwd_fix_missing',
  );
  files[member] = Uint8List.fromList(
    utf8.encode(
      original.replaceFirst(
        '  cd -- "\$work/source"',
        '  : # historical inherited cwd',
      ),
    ),
  );
  Directory(directory).createSync(recursive: true);
  const name = 'sky-ui-linux-amd64.tar.gz';
  final bytes = packTar(files);
  File('$directory/$name').writeAsBytesSync(bytes);
  File('$directory/$name.sha256')
      .writeAsStringSync('${digest(bytes)}  $name\n');
  stdout.writeln('Prepared private SDK-probe failure fixture.');
}
