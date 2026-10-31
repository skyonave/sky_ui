import 'dart:convert';
import 'dart:io';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'errors.dart';

class CoreReleases {
  CoreReleases({this.fetch});
  final Future<dynamic> Function(
    String repository,
    String path,
    Map<String, String>? query,
  )?
  fetch;
  static const repositories = coreRepositories;
  final _cache = <String, ({DateTime time, CoreReleaseNotes value})>{};
  final _pending = <String, Future<CoreReleaseNotes>>{};
  static List<int>? version(String? text) {
    final m = RegExp(r'v?(\d+)\.(\d+)\.(\d+)').firstMatch(text ?? '');
    return m == null ? null : [for (var i = 1; i <= 3; i++) int.parse(m[i]!)];
  }

  static int compare(List<int> a, List<int> b) {
    for (var i = 0; i < 3; i++) {
      final n = a[i].compareTo(b[i]);
      if (n != 0) return n;
    }
    return 0;
  }

  Future<CoreReleaseNotes> get(String core, String? installed) async {
    if (!repositories.containsKey(core))
      throw const ApiException('instance_not_found', status: 404);
    final key = '$core/$installed', cached = _cache['$core/$installed'];
    if (cached != null &&
        DateTime.now().difference(cached.time) < const Duration(minutes: 10))
      return cached.value;
    return _pending.putIfAbsent(key, () async {
      try {
        final value = await _load(core, installed);
        _cache[key] = (time: DateTime.now(), value: value);
        return value;
      } finally {
        _pending.remove(key);
      }
    });
  }

  Future<CoreReleaseNotes> _load(String core, String? installed) async {
    final repo = repositories[core]!;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = ((_) => 'DIRECT');
    try {
      Future<dynamic> read(String path, {Map<String, String>? query}) async {
        if (fetch != null) return fetch!(repo, path, query);
        final request = await client
            .getUrl(Uri.https('api.github.com', '/repos/$repo/$path', query))
            .timeout(const Duration(seconds: 6));
        request.followRedirects = false;
        request.headers.set('User-Agent', 'Sky-UI');
        request.headers.set('Accept', 'application/vnd.github+json');
        request.headers.set('X-GitHub-Api-Version', '2026-03-10');
        final response = await request.close().timeout(
          const Duration(seconds: 6),
        );
        if (response.statusCode != 200)
          throw ApiException(
            response.statusCode == 403 || response.statusCode == 429
                ? 'releases_rate_limited'
                : 'releases_unavailable',
            status: 503,
          );
        final bytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 6),
        )) {
          if (bytes.length + chunk.length > 2097152)
            throw const ApiException('releases_unavailable', status: 503);
          bytes.addAll(chunk);
        }
        return jsonDecode(utf8.decode(bytes));
      }

      CoreRelease parse(Map<String, dynamic> data) {
        final tag = data['tag_name'] as String;
        final uri = Uri.tryParse(data['html_url'] as String? ?? '');
        if (uri?.scheme != 'https' ||
            uri?.host != 'github.com' ||
            !uri!.path.startsWith('/$repo/releases/'))
          throw const FormatException();
        final body = data['body'] as String? ?? '';
        return CoreRelease(
          tag: tag,
          name: data['name'] as String? ?? tag,
          body: body.length > 65536 ? body.substring(0, 65536) : body,
          url: uri.toString(),
          date: data['published_at'] as String? ?? '',
        );
      }

      final raw = await read('releases/latest') as Map<String, dynamic>;
      final latest = parse(raw),
          current = version(installed),
          newest = version(latest.tag);
      var notes = <CoreRelease>[latest], incomplete = false;
      if (current != null && newest != null && compare(current, newest) < 0) {
        notes = [];
        var reached = false;
        for (var page = 1; page <= 3; page++) {
          // Query parameters are added separately; repository paths are fixed.
          final data =
              await read('releases', query: {'per_page': '20', 'page': '$page'})
                  as List;
          if (data.isEmpty) {
            reached = true;
            break;
          }
          for (final item in data.cast<Map<String, dynamic>>()) {
            if (item['draft'] == true || item['prerelease'] == true) continue;
            final release = parse(item), v = version(release.tag);
            if (v == null) continue;
            if (compare(v, current) <= 0) continue;
            if (compare(v, newest) <= 0 &&
                !notes.any((n) => n.tag == release.tag))
              notes.add(release);
          }
          // Backport releases can appear ahead of newer version numbers.
          // Only exhausted pagination proves the bounded history is complete.
          if (data.length < 20) {
            reached = true;
            break;
          }
        }
        incomplete = !reached;
        notes.sort((a, b) => compare(version(b.tag)!, version(a.tag)!));
        if (notes.isEmpty) {
          notes = [latest];
          incomplete = true;
        }
      }
      return CoreReleaseNotes(
        coreId: core,
        repository: 'https://github.com/$repo/releases',
        installed: installed,
        latest: latest.tag,
        releases: notes,
        incomplete: incomplete,
      );
    } on ApiException {
      rethrow;
    } on Object {
      throw const ApiException('releases_unavailable', status: 503);
    } finally {
      client.close(force: true);
    }
  }
}
