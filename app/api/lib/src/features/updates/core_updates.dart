import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../bootstrap/server_config.dart';
import '../../shared/api_exception.dart';

class CoreUpdates {
  CoreUpdates({this.fetch, this.platform, this.panelVersion});
  final Future<dynamic> Function(Uri source)? fetch;
  final String? platform, panelVersion;
  static const base =
      'https://raw.githubusercontent.com/skyonave/sky_ui/main/compatibility/cores';
  final _cache = <String, ({DateTime time, Map<String, dynamic> catalog})>{};
  final _pending = <String, Future<Map<String, dynamic>>>{};
  String get targetPlatform =>
      platform ??
      switch (Abi.current()) {
        Abi.linuxX64 => 'linux-amd64',
        Abi.linuxArm64 => 'linux-arm64',
        _ => 'unsupported',
      };
  static List<int>? version(String? value) {
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(value ?? '');
    return match == null
        ? null
        : [for (var i = 1; i <= 3; i++) int.parse(match[i]!)];
  }

  static int compare(List<int> left, List<int> right) {
    for (var i = 0; i < 3; i++) {
      final difference = left[i].compareTo(right[i]);
      if (difference != 0) return difference;
    }
    return 0;
  }

  Future<Map<String, dynamic>> _read(String core, {bool fresh = false}) async {
    if (!coreRepositories.containsKey(core))
      throw const ApiException('core_unsupported', status: 404);
    final cached = _cache[core];
    if (!fresh &&
        cached != null &&
        DateTime.now().difference(cached.time) < const Duration(minutes: 5)) {
      return cached.catalog;
    }
    return _pending.putIfAbsent(core, () async {
      final source = Uri.parse('$base/$core.json');
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 5)
        ..findProxy = (_) => 'DIRECT';
      try {
        dynamic value;
        if (fetch != null) {
          value = await fetch!(source);
        } else {
          final request = await client
              .getUrl(source)
              .timeout(const Duration(seconds: 6));
          request.followRedirects = false;
          request.headers.set('User-Agent', 'Sky-UI');
          final response = await request.close().timeout(
            const Duration(seconds: 6),
          );
          if (response.statusCode != 200)
            throw const ApiException('catalog_unavailable', status: 503);
          final bytes = <int>[];
          await for (final chunk in response.timeout(
            const Duration(seconds: 6),
          )) {
            if (bytes.length + chunk.length > 262144)
              throw const FormatException();
            bytes.addAll(chunk);
          }
          value = jsonDecode(utf8.decode(bytes));
        }
        if (value is! Map<String, dynamic> ||
            value['schemaVersion'] != 1 ||
            value['coreId'] != core ||
            value['releases'] is! List ||
            (value['releases'] as List).length > 256) {
          throw const FormatException();
        }
        _cache[core] = (time: DateTime.now(), catalog: value);
        return value;
      } on ApiException {
        rethrow;
      } on Object {
        throw const ApiException('catalog_unavailable', status: 503);
      } finally {
        client.close(force: true);
        _pending.remove(core);
      }
    });
  }

  Future<List<String>> approved(String core, {bool fresh = false}) async {
    final catalog = await _read(core, fresh: fresh);
    try {
      final versions = <String>{};
      final seen = <String>{};
      for (final raw in catalog['releases'] as List) {
        final release = Map<String, dynamic>.from(raw as Map);
        if (release['verified'] != true) continue;
        final tag = release['version'] as String;
        if (!tag.startsWith('v') || version(tag) == null || !seen.add(tag))
          throw const FormatException();
        if (!(release['panelVersions'] as List).contains(
          panelVersion ?? skyUiVersion,
        ))
          continue;
        final platforms = release['platforms'] as Map;
        final asset = platforms[targetPlatform];
        if (asset is! Map || asset['verified'] != true) continue;
        if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(asset['asset'] as String) ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(asset['sha256'] as String))
          throw const FormatException();
        versions.add(tag);
      }
      return versions.toList()
        ..sort((a, b) => compare(version(b)!, version(a)!));
    } on Object {
      throw const ApiException('catalog_unavailable', status: 503);
    }
  }

  Future<void> requireApproved(String core, String tag) async {
    if (!(await approved(core, fresh: true)).contains(tag)) {
      throw const ApiException('core_release_unverified', status: 422);
    }
  }

  Future<CoreUpdateInfo> get(String core, String? installed) async {
    final approvedVersions = await approved(core);
    final current = version(installed);
    return CoreUpdateInfo(
      coreId: core,
      source: '$base/$core.json',
      installed: installed,
      versions: current == null
          ? approvedVersions
          : approvedVersions
                .where((tag) => compare(version(tag)!, current) > 0)
                .toList(),
      checkedAt: DateTime.now().toUtc().toIso8601String(),
    );
  }
}
