import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../platform/host.dart';

const _repository = 'MetaCubeX/meta-rules-dat';
const _maximumBytes = 64 * 1024 * 1024;

/// Only generated references are eligible; configuration cannot supply URLs.
Map<String, Uri> nodeRoutingAssets(
  String engine,
  Map<String, dynamic> config,
  String runtimeDirectory,
) {
  final assets = <String, Uri>{};
  Uri release(String asset) =>
      Uri.https('github.com', '/$_repository/releases/download/latest/$asset');
  if (engine == 'mihomo') {
    final rules = <String>[
      ...((config['rules'] as List?) ?? const []).whereType<String>(),
      if (config['sub-rules'] is Map)
        for (final list in (config['sub-rules'] as Map).values)
          if (list is List) ...list.whereType<String>(),
    ];
    if (rules.any((r) => r.startsWith('GEOSITE,'))) {
      assets['$runtimeDirectory/GeoSite.dat'] = release('geosite.dat');
    }
    if (rules.any(
      (r) => r.startsWith('GEOIP,') && !r.startsWith('GEOIP,LAN,'),
    )) {
      final geodata = config['geodata-mode'] == true;
      assets['$runtimeDirectory/${geodata ? 'GeoIP.dat' : 'geoip.metadb'}'] =
          release(geodata ? 'geoip.dat' : 'geoip.metadb');
    }
  } else if (engine == 'xray') {
    final routing = config['routing'];
    final rules = routing is Map ? routing['rules'] : null;
    if (rules is! List) return assets;
    for (final (kind, field) in [('geosite', 'domain'), ('geoip', 'ip')]) {
      final asset = 'sky-ui-$kind.dat';
      if (rules.whereType<Map>().any(
        (r) =>
            r[field] is List &&
            (r[field] as List).whereType<String>().any(
              (v) => v.startsWith('ext:$asset:'),
            ),
      )) {
        assets['$runtimeDirectory/$asset'] = release('$kind.dat');
      }
    }
  } else if (engine == 'sing-box') {
    final route = config['route'];
    final sets = route is Map ? route['rule_set'] : null;
    if (sets is! List) return assets;
    for (final set in sets.whereType<Map>()) {
      final tag = set['tag'];
      final match = tag is String
          ? RegExp(
              r'^sky-ui/routing/(geosite|geoip)/([a-z0-9][a-z0-9_-]{0,63})$',
            ).firstMatch(tag)
          : null;
      if (match == null) continue;
      final kind = match[1]!, value = match[2]!;
      final path = '$runtimeDirectory/sky-ui-$kind-$value.srs';
      require(
        set['type'] == 'local' &&
            set['format'] == 'binary' &&
            set['path'] == path,
        'route_policy_invalid',
      );
      assets[path] = Uri.https(
        'raw.githubusercontent.com',
        '/$_repository/sing/geo/$kind/$value.srs',
      );
    }
  }
  require(assets.length <= 256, 'route_policy_invalid');
  return assets;
}

/// Use the same upstream cache policy as local routing data preparation.
/// Core artifacts remain checksum-pinned separately; mutable rule feeds do not.
Future<void> prepareNodeRoutingData(
  String engine,
  String configuration,
  String runtimeDirectory,
) async {
  final config = object(jsonDecode(readText(configuration, 524288)));
  final assets = nodeRoutingAssets(engine, config, runtimeDirectory);
  if (assets.isEmpty) return;
  final user = await account('sky-ui-relay');
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionTimeout = const Duration(seconds: 5);
  var expired = false;
  final deadline = Timer(const Duration(seconds: 45), () {
    expired = true;
    client.close(force: true);
  });
  try {
    for (final entry in assets.entries) {
      require(!expired, 'route_geo_unavailable');
      if (exists(entry.key)) {
        // Existing native Mihomo downloads may belong to its unprivileged user.
        // Never follow a planted symlink or accept an oversized cache.
        final fd = host.open(entry.key, 'read');
        try {
          final stat = host.metadata(fd);
          require(
            stat[0] & 0xf000 == 0x8000 &&
                stat[3] == 1 &&
                (stat[1] == 0 || stat[1] == user.uid) &&
                stat[4] <= _maximumBytes,
            'unsafe_file',
          );
          if (stat[4] > 0) continue;
        } finally {
          host.close(fd);
        }
      }
      final bytes = await _download(client, entry.value);
      require(!expired, 'route_geo_unavailable');
      host.atomic(entry.key, bytes, mode: 0x1a0, gid: user.gid);
    }
  } on IOException {
    throw const OpsError('route_geo_unavailable');
  } on TimeoutException {
    throw const OpsError('route_geo_unavailable');
  } finally {
    deadline.cancel();
    client.close(force: true);
  }
}

Future<Uint8List> _download(HttpClient client, Uri uri) async {
  const allowed = {
    'github.com',
    'raw.githubusercontent.com',
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
  };
  for (var redirects = 0; redirects < 6; redirects++) {
    require(
      uri.scheme == 'https' &&
          allowed.contains(uri.host) &&
          uri.port == 443 &&
          uri.userInfo.isEmpty &&
          !uri.hasFragment,
      'route_geo_unavailable',
    );
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 5));
    request.followRedirects = false;
    request.headers.set('User-Agent', 'Sky-UI');
    final response = await request.close().timeout(const Duration(seconds: 10));
    if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
      final location = response.headers.value('location');
      require(location != null, 'route_geo_unavailable');
      uri = uri.resolve(location!);
      await response.drain<void>().timeout(const Duration(seconds: 5));
      continue;
    }
    require(response.statusCode != HttpStatus.notFound, 'route_geo_unknown');
    require(
      response.statusCode == HttpStatus.ok &&
          response.contentLength <= _maximumBytes,
      'route_geo_unavailable',
    );
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 10))) {
      require(
        bytes.length + chunk.length <= _maximumBytes,
        'route_geo_unavailable',
      );
      bytes.add(chunk);
    }
    require(bytes.length > 0, 'route_geo_unavailable');
    return bytes.takeBytes();
  }
  throw const OpsError('route_geo_unavailable');
}
