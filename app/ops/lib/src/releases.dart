import 'dart:convert';
import 'dart:typed_data';

import 'host.dart';
import 'artifacts.dart';

const repository = 'https://github.com/skyonave/sky_ui';
const feed =
    'https://api.github.com/repos/skyonave/sky_ui/releases?per_page=20';
Map<String, dynamic>? releaseAssets(
  Map<String, dynamic> release,
  String platform,
) {
  if (!['linux-amd64', 'linux-arm64'].contains(platform)) return null;
  final bundle = 'sky-ui-$platform.tar.gz', tag = release['tag_name'];
  final required = {
    bundle: 160 * 1024 * 1024,
    '$bundle.sha256': 4096,
    'install.sh': 262144,
    'install.sh.sha256': 4096,
  };
  final list = release['assets'];
  if (list is! List || list.length > 100) return null;
  final result = <String, dynamic>{};
  for (final value in list) {
    final item = object(value), name = item['name'];
    if (!required.containsKey(name)) continue;
    if (result.containsKey(name) ||
        item['state'] != 'uploaded' ||
        item['size'] is! int ||
        item['size'] <= 0 ||
        item['size'] > required[name] ||
        item['digest'] is! String ||
        !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(item['digest']) ||
        item['browser_download_url'] !=
            '$repository/releases/download/$tag/$name')
      return null;
    result[name as String] = item;
  }
  return result.length == required.length ? result : null;
}

Future<Map<String, dynamic>?> candidate(
  String currentVersion,
  String platform, {
  String? requested,
  Fetch? fetch,
}) async {
  require(
    parseVersion(currentVersion) != null &&
        (requested == null ||
            parseVersion(requested) != null && requested.startsWith('v')),
    'release_invalid',
  );
  if (!['linux-amd64', 'linux-arm64'].contains(platform)) return null;
  try {
    final list = jsonDecode(
      utf8.decode(await (fetch ?? httpBytes)(feed, 2 * 1024 * 1024)),
    );
    require(list is List && list.length <= 20, 'release_feed_unavailable');
    final choices = <Map<String, dynamic>>[];
    for (final value in list) {
      final release = object(value),
          tag = release['tag_name'],
          version = parseVersion(release['tag_name']);
      if (version == null ||
          !(tag as String).startsWith('v') ||
          release['draft'] != false ||
          compareVersions(tag, currentVersion) <= 0 ||
          parseVersion(currentVersion)!.pre.isEmpty &&
              (version.pre.isNotEmpty || release['prerelease'] == true) ||
          requested != null && requested != tag)
        continue;
      final assets = releaseAssets(release, platform);
      if (assets != null) choices.add({'tag': tag, 'assets': assets});
    }
    choices.sort(
      (a, b) => compareVersions(b['tag'] as String, a['tag'] as String),
    );
    return choices.isEmpty ? null : choices.first;
  } on OpsError {
    rethrow;
  } on Object {
    throw const OpsError('release_feed_unavailable');
  }
}

Future<Map<String, dynamic>> discover(
  String version,
  String platform, {
  String? tag,
  Fetch? fetch,
}) async {
  final found = await candidate(
    version,
    platform,
    requested: tag,
    fetch: fetch,
  );
  return {
    'currentVersion': version,
    'available': found != null,
    'latestVersion': found == null
        ? null
        : (found['tag'] as String).substring(1),
    'tag': found?['tag'],
    'releaseUrl': found == null
        ? null
        : '$repository/releases/tag/${found['tag']}',
    'supported': ['linux-amd64', 'linux-arm64'].contains(platform),
    'checkedAt': now(),
  };
}

Future<void> prepareRelease(
  Map<String, dynamic> release,
  String platform,
  String destination, {
  Fetch? fetch,
  void Function(int, int, String)? onProgress,
  void Function()? onVerify,
}) async {
  final assets = object(release['assets']), files = <String, Uint8List>{};
  final total = assets.values.fold<int>(0, (a, b) => a + (b['size'] as int));
  var received = 0;
  for (final entry in assets.entries) {
    final metadata = object(entry.value);
    final bytes = fetch != null
        ? await fetch(
            metadata['browser_download_url'] as String,
            metadata['size'] as int,
          )
        : await httpBytes(
            metadata['browser_download_url'] as String,
            metadata['size'] as int,
            progress: (n) => onProgress?.call(received + n, total, entry.key),
          );
    files[entry.key] = bytes;
    received += bytes.length;
    onProgress?.call(received, total, entry.key);
  }
  onVerify?.call();
  for (final entry in files.entries) {
    final meta = assets[entry.key];
    require(
      entry.value.length == meta['size'] &&
          'sha256:${digest(entry.value)}' == meta['digest'],
      'release_checksum_failed',
    );
  }
  for (final name in ['install.sh', 'sky-ui-$platform.tar.gz']) {
    final parts = ascii
        .decode(files['$name.sha256']!)
        .trim()
        .split(RegExp(r'\s+'));
    require(
      parts.length == 2 && parts[1] == name && parts[0] == digest(files[name]!),
      'release_checksum_failed',
    );
  }
  for (final entry in files.entries) {
    require(!exists('$destination/${entry.key}'), 'unsafe_file');
    host.atomic('$destination/${entry.key}', entry.value, mode: 0x180);
  }
}
