import '../../shared/api_exception.dart';

typedef BootstrapCoreAsset = ({String version, String asset, String sha256});

/// Bootstrap follows the same exact panel approval as later core installations.
Map<String, BootstrapCoreAsset> selectNodeBootstrapAssets(
  Map<String, dynamic> catalog,
  String panelVersion,
) {
  if (catalog['schemaVersion'] != 1 ||
      catalog['coreId'] != 'mihomo' ||
      catalog['releases'] is! List ||
      (catalog['releases'] as List).length > 256) {
    throw const ApiException('server_bootstrap_unavailable', status: 501);
  }
  final approved = <({Map release, String version, List<int> numbers})>[];
  for (final release in (catalog['releases'] as List).whereType<Map>()) {
    final version = release['version'];
    if (release['verified'] != true ||
        version is! String ||
        !RegExp(r'^v[0-9]+\.[0-9]+\.[0-9]+$').hasMatch(version) ||
        release['panelVersions'] is! List ||
        !(release['panelVersions'] as List).contains(panelVersion))
      continue;
    final numbers = version.substring(1).split('.').map(int.tryParse).toList();
    if (numbers.any((v) => v == null)) continue;
    approved.add((
      release: release,
      version: version,
      numbers: numbers.cast<int>(),
    ));
  }
  approved.sort((a, b) {
    for (var i = 0; i < 3; i++) {
      final order = b.numbers[i].compareTo(a.numbers[i]);
      if (order != 0) return order;
    }
    return 0;
  });
  final selected = <String, BootstrapCoreAsset>{};
  for (final candidate in approved) {
    for (final entry in {
      'x86_64': 'linux-amd64',
      'aarch64': 'linux-arm64',
    }.entries) {
      if (selected.containsKey(entry.key)) continue;
      final platforms = candidate.release['platforms'];
      final platform = platforms is Map ? platforms[entry.value] : null;
      if (platform is! Map || platform['verified'] != true) continue;
      final asset = platform['asset'], sha = platform['sha256'];
      if (asset is! String ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,255}\.gz$').hasMatch(asset) ||
          sha is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha))
        continue;
      selected[entry.key] = (
        version: candidate.version,
        asset: asset,
        sha256: sha,
      );
    }
  }
  return selected;
}
