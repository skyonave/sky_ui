import 'dart:async';
import 'dart:io';

import '../../infrastructure/process/command_runner.dart';
import '../../shared/api_exception.dart';
import '../managed_core.dart';

/// Generated rule sets are cached beside the engine configuration.
class RoutingGeoData {
  static const prefix = 'sky-ui/routing/';
  static const _repository = 'MetaCubeX/meta-rules-dat';
  static final _singTag = RegExp(
    r'^sky-ui/routing/(geosite|geoip)/([a-z0-9][a-z0-9_-]{0,63})$',
  );
  static const _maxBytes = 64 * 1024 * 1024;

  static String xrayAsset(String kind) => 'sky-ui-$kind.dat';
  static String singTag(String kind, String value) => '$prefix$kind/$value';
  static String singPath(String directory, String kind, String value) =>
      '$directory/sky-ui-$kind-$value.srs';

  static Future<void> prepare(
    ManagedCore core,
    Map<String, dynamic> config,
    CommandRunner runner,
  ) async {
    final downloads = <String, Uri>{};
    if (core.coreId == 'xray') {
      final routing = config['routing'];
      final rules = routing is Map ? routing['rules'] : null;
      if (rules is! List) return;
      for (final (kind, field) in [('geosite', 'domain'), ('geoip', 'ip')]) {
        final asset = xrayAsset(kind);
        if (rules.whereType<Map>().any((rule) {
          final values = rule[field];
          return values is List &&
              values.whereType<String>().any(
                (v) => v.startsWith('ext:$asset:'),
              );
        })) {
          downloads['${core.directory}/$asset'] = Uri.https(
            'github.com',
            '/$_repository/releases/download/latest/$kind.dat',
          );
        }
      }
    } else {
      final route = config['route'];
      final ruleSets = route is Map ? route['rule_set'] : null;
      if (ruleSets is! List) return;
      for (final set in ruleSets.whereType<Map>()) {
        final tag = set['tag'];
        final match = tag is String ? _singTag.firstMatch(tag) : null;
        if (match == null) continue;
        final kind = match[1]!, value = match[2]!;
        final path = singPath(core.directory, kind, value);
        if (set['type'] != 'local' || set['path'] != path) continue;
        downloads[path] = Uri.https(
          'raw.githubusercontent.com',
          '/$_repository/sing/geo/$kind/$value.srs',
        );
      }
    }
    for (final entry in downloads.entries) {
      final destination = File(entry.key);
      if (await destination.exists() && await destination.length() > 0) {
        continue;
      }
      await _download(entry.value, destination, runner);
    }
  }

  static Future<void> _download(
    Uri source,
    File destination,
    CommandRunner runner,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    final temporary = File(
      '${destination.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    final deadline = Timer(
      const Duration(seconds: 15),
      () => client.close(force: true),
    );
    try {
      await temporary.create(exclusive: true);
      await _receive(client, source, temporary);
      if (Platform.isLinux) {
        final result = await runner.run('/usr/bin/chmod', [
          '0640',
          temporary.path,
        ]);
        if (result.exitCode != 0) {
          throw const ApiException('route_geo_unavailable', status: 422);
        }
      }
      await temporary.rename(destination.path);
    } on IOException {
      throw const ApiException('route_geo_unavailable', status: 422);
    } finally {
      deadline.cancel();
      client.close(force: true);
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static Future<void> _receive(HttpClient client, Uri source, File file) async {
    final response = await (await client.getUrl(source)).close();
    if (response.statusCode == HttpStatus.notFound) {
      throw const ApiException('route_geo_unknown', status: 422);
    }
    if (response.statusCode != HttpStatus.ok ||
        response.contentLength > _maxBytes) {
      throw const ApiException('route_geo_unavailable', status: 422);
    }
    final output = await file.open(mode: FileMode.writeOnly);
    try {
      var length = 0;
      await for (final chunk in response) {
        length += chunk.length;
        if (length > _maxBytes) {
          throw const ApiException('route_geo_unavailable', status: 422);
        }
        await output.writeFrom(chunk);
      }
      if (length == 0) {
        throw const ApiException('route_geo_unavailable', status: 422);
      }
    } finally {
      await output.close();
    }
  }
}
