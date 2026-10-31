import 'package:sky_ui_api/src/core_releases.dart';
import 'package:test/test.dart';

void main() {
  Map<String, Object?> release(String tag, {bool prerelease = false}) => {
    'tag_name': tag,
    'name': tag,
    'body': 'Notes for $tag',
    'html_url': 'https://github.com/MetaCubeX/mihomo/releases/tag/$tag',
    'published_at': '2026-10-31T00:00:00Z',
    'draft': false,
    'prerelease': prerelease,
  };

  test(
    'a recently published backport does not hide newer versions on later pages',
    () async {
      final service = CoreReleases(
        fetch: (repo, path, query) async {
          if (path == 'releases/latest') return release('v1.10.0');
          if (query?['page'] == '1')
            return [
              release('v1.8.10'),
              ...List.generate(19, (_) => release('v1.10.0')),
            ];
          return [release('v1.9.1')];
        },
      );
      final result = await service.get('mihomo', 'v1.9.0');
      expect(result.releases.map((r) => r.tag), ['v1.10.0', 'v1.9.1']);
      expect(result.incomplete, false);
    },
  );
  test(
    'uninstalled core gets latest notes only and requests are cached',
    () async {
      var calls = 0;
      final service = CoreReleases(
        fetch: (repo, path, query) async {
          calls++;
          expect(path, 'releases/latest');
          return release('v1.10.0');
        },
      );
      final result = await service.get('mihomo', null);
      expect(result.installed, isNull);
      expect(result.releases.single.tag, 'v1.10.0');
      await service.get('mihomo', null);
      expect(calls, 1);
    },
  );
  test(
    'history contains stable releases newer than installed, in numeric version order',
    () async {
      final service = CoreReleases(
        fetch: (repo, path, query) async {
          if (path == 'releases/latest') return release('v1.10.0');
          expect(query?['per_page'], '20');
          return [
            release('v1.11.0-alpha', prerelease: true),
            release('v1.9.1'),
            release('v1.10.0'),
            release('v1.9.0'),
            release('v1.8.9'),
          ];
        },
      );
      final result = await service.get(
        'mihomo',
        'Mihomo Meta v1.9.0 linux amd64',
      );
      expect(result.releases.map((r) => r.tag), ['v1.10.0', 'v1.9.1']);
      expect(result.incomplete, false);
    },
  );
  test(
    'bounded history reports incomplete coverage instead of claiming all changes',
    () async {
      final service = CoreReleases(
        fetch: (repo, path, query) async {
          if (path == 'releases/latest') return release('v1.10.0');
          return List.generate(20, (_) => release('v1.10.0'));
        },
      );
      final result = await service.get('mihomo', 'v1.0.0');
      expect(result.incomplete, true);
    },
  );
}
