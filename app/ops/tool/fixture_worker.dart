import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sky_ui_ops/src/platform/host.dart';
import 'package:sky_ui_ops/src/features/maintenance/worker.dart';
import 'package:sky_ui_ops/src/shared/progress.dart';
import 'package:sky_ui_ops/src/features/updates/panel_updater.dart';

import 'installed_acceptance.dart' show isolated;

// Offline artifact transport belongs only to the guarded acceptance executable.
// Installed sky-ops has no fixture flags, environment overrides or fallback feed.
Future<void> main(List<String> args) async {
  isolated();
  require(
    args.length == 1 || args.length == 2 && args[1] == '--panel',
    'fixture_directory_required',
  );
  final root = args.first;
  final index = object(
    jsonDecode(File('$root/http-index.json').readAsStringSync()),
  );
  Future<Uint8List> fetch(String url, int limit) async {
    final metadata = object(index[url]);
    final name = metadata['name'] as String;
    require(RegExp(r'^[a-f0-9]{64}$').hasMatch(name), 'fixture_file_invalid');
    final bytes = File('$root/http/$name').readAsBytesSync();
    require(
      bytes.length <= limit && digest(bytes) == metadata['sha256'],
      'fixture_checksum_failed',
    );
    return bytes;
  }

  Future<Uint8List> cachedAwg(
    Uint8List source,
    String work,
    String tag,
    Reporter? reporter,
  ) async {
    final receipt = object(
      jsonDecode(File('$root/amneziawg.artifact.json').readAsStringSync()),
    );
    final binary = File('$root/amneziawg').readAsBytesSync();
    require(
      receipt['version'] == tag &&
          receipt['archiveSha256'] == digest(source) &&
          receipt['binarySha256'] == digest(binary),
      'fixture_checksum_failed',
    );
    return binary;
  }

  if (args.length == 2) {
    await panelUpdateMain([], fetch: fetch);
  } else {
    await maintenanceMain([], fetch: fetch, compileAwg: cachedAwg);
  }
}
