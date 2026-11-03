import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../platform/host.dart';
import 'archives.dart';

const catalogBase =
    'https://raw.githubusercontent.com/skyonave/sky_ui/main/compatibility/cores';
const repositories = {
  'mihomo': 'MetaCubeX/mihomo',
  'sing-box': 'SagerNet/sing-box',
  'xray': 'XTLS/Xray-core',
  'amneziawg': 'amnezia-vpn/amneziawg-go',
};
typedef Fetch = Future<Uint8List> Function(String url, int limit);
String targetPlatform() => switch (Abi.current()) {
  Abi.linuxX64 => 'linux-amd64',
  Abi.linuxArm64 => 'linux-arm64',
  _ => 'unsupported',
};
Future<({String tag, String url, String sha})> verifiedRelease(
  String core,
  String panel,
  String platform, {
  String? selected,
  Fetch? fetch,
}) async {
  require(
    repositories.containsKey(core) &&
        (selected == null || coreTagPattern.hasMatch(selected)),
    'core_release_unverified',
  );
  try {
    final catalog = object(
      jsonDecode(
        utf8.decode(
          await (fetch ?? httpBytes)('$catalogBase/$core.json', 262144),
        ),
      ),
    );
    require(
      catalog['schemaVersion'] is int &&
          catalog['schemaVersion'] == 1 &&
          catalog['coreId'] == core &&
          catalog['releases'] is List &&
          (catalog['releases'] as List).length <= 256,
      'catalog_unavailable',
    );
    final approved = <({String tag, Map<String, dynamic> asset})>[],
        seen = <String>{};
    for (final value in catalog['releases']) {
      final release = object(value);
      if (release['verified'] != true) continue;
      final tag = release['version'] as String;
      require(
        coreTagPattern.hasMatch(tag) &&
            seen.add(tag) &&
            release['panelVersions'] is List,
        'catalog_unavailable',
      );
      if (!(release['panelVersions'] as List).contains(panel)) continue;
      final asset = release['platforms'][platform];
      if (asset is! Map || asset['verified'] != true) continue;
      require(
        RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$')
                .hasMatch(asset['asset'] as String) &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch(asset['sha256'] as String),
        'catalog_unavailable',
      );
      approved.add((tag: tag, asset: object(asset)));
    }
    approved.sort((a, b) => compareVersions(b.tag, a.tag));
    final matches = approved.where(
      (r) => selected == null || r.tag == selected,
    );
    require(matches.isNotEmpty, 'core_release_unverified');
    final chosen = matches.first;
    return (
      tag: chosen.tag,
      url: core == 'amneziawg'
          ? 'https://github.com/${repositories[core]}/archive/refs/tags/${chosen.tag}.tar.gz'
          : 'https://github.com/${repositories[core]}/releases/download/${chosen.tag}/${chosen.asset['asset']}',
      sha: chosen.asset['sha256'] as String,
    );
  } on OpsError {
    rethrow;
  } on Object {
    throw const OpsError('catalog_unavailable');
  }
}

Future<Map<String, Uint8List>> artifactFiles(
  String core,
  String tag,
  String url,
  String sha,
  String platform, {
  Fetch? fetch,
}) async {
  final get = fetch ?? httpBytes;
  require(repositories.containsKey(core), 'core_unsupported');
  final compressed = await get(url, 64 * 1024 * 1024);
  require(digest(compressed) == sha, 'release_checksum_failed');
  final license = await get(
    'https://raw.githubusercontent.com/${repositories[core]}/$tag/LICENSE',
    1048576,
  );
  require(utf8.decode(license).trim().isNotEmpty, 'license_invalid');
  final receipt = <String, dynamic>{
    'coreId': core,
    'version': tag,
    'platform': platform,
    'archiveSha256': sha,
    'source': url,
  };
  if (core == 'amneziawg')
    return {
      'source.tar.gz': compressed,
      'LICENSE': license,
      'artifact.json': Uint8List.fromList(utf8.encode(jsonEncode(receipt))),
    };
  Uint8List binary;
  if (core == 'xray') {
    final entries = ZipDecoder()
        .decodeBytes(compressed)
        .files
        .where((f) => f.name == 'xray')
        .toList();
    require(
      entries.length == 1 &&
          entries.single.isFile &&
          !entries.single.isSymbolicLink &&
          entries.single.size <= 100 * 1024 * 1024,
      'archive_invalid',
    );
    binary = Uint8List.fromList(entries.single.readBytes()!);
  } else if (core == 'sing-box') {
    final entries = tarSelected(
      compressed,
      (name) => basename(name) == 'sing-box',
      limit: 120 * 1024 * 1024,
    ).entries.where((e) => basename(e.key) == 'sing-box').toList();
    require(entries.length == 1, 'archive_invalid');
    binary = entries.single.value;
  } else {
    binary = GZipDecoder().decodeBytes(
      compressed,
      verify: true,
      maxOutputSize: 100 * 1024 * 1024,
    );
  }
  require(
    binary.length >= 64 &&
        binary.length <= 100 * 1024 * 1024 &&
        binary.take(6).join(',') == '127,69,76,70,2,1' &&
        ByteData.sublistView(binary).getUint16(18, Endian.little) ==
            (platform == 'linux-amd64'
                ? 62
                : platform == 'linux-arm64'
                ? 183
                : -1),
    'binary_invalid',
  );
  receipt.addAll({
    'binarySha256': digest(binary),
    'sourceCode': 'https://github.com/${repositories[core]}/tree/$tag',
  });
  return {
    core: binary,
    'LICENSE': license,
    'artifact.json': Uint8List.fromList(utf8.encode(jsonEncode(receipt))),
  };
}

final versionPattern = RegExp(
  r'^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
);
({List<int> numbers, List<String> pre})? parseVersion(Object? value) {
  if (value is! String || value.length > 96) return null;
  final m = versionPattern.firstMatch(value);
  if (m == null) return null;
  final pre = m[4]?.split('.') ?? <String>[];
  if (pre.any(
    (x) => RegExp(r'^[0-9]+$').hasMatch(x) && x.length > 1 && x.startsWith('0'),
  ))
    return null;
  final numbers = [for (var i = 1; i < 4; i++) int.tryParse(m[i]!)];
  if (numbers.any((n) => n == null)) return null;
  return (numbers: numbers.cast<int>(), pre: pre);
}

int compareVersions(String a, String b) {
  final left = parseVersion(a), right = parseVersion(b);
  require(left != null && right != null, 'release_invalid');
  for (var i = 0; i < 3; i++) {
    final n = left!.numbers[i].compareTo(right!.numbers[i]);
    if (n != 0) return n;
  }
  final x = left!.pre, y = right!.pre;
  if (x.isEmpty || y.isEmpty) return x.isEmpty ? (y.isEmpty ? 0 : 1) : -1;
  for (var i = 0; i < x.length && i < y.length; i++) {
    if (x[i] == y[i]) continue;
    final xn = int.tryParse(x[i]), yn = int.tryParse(y[i]);
    if (xn != null && yn != null) return xn.compareTo(yn);
    if ((xn == null) != (yn == null)) return xn != null ? -1 : 1;
    return x[i].compareTo(y[i]);
  }
  return x.length.compareTo(y.length);
}
