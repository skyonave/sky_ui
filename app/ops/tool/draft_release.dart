import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sky_ui_ops/src/shared/archives.dart';
import 'package:sky_ui_ops/src/platform/host.dart'
    show OpsError, digest, require;

import 'native_manifest.dart' show buildSources, elfMatches;

const repo = 'skyonave/sky_ui';
const standaloneInstallers = {
  'install.sh': 'install.sh',
  'install-server-node.sh': 'deploy/install-server-node.sh',
};
final assetNames = List<String>.unmodifiable([
  'sky-ui-linux-amd64.tar.gz',
  'sky-ui-linux-amd64.tar.gz.sha256',
  'sky-ui-linux-arm64.tar.gz',
  'sky-ui-linux-arm64.tar.gz.sha256',
  for (final name in standaloneInstallers.keys) ...[name, '$name.sha256'],
]);

void checkBundledNodeInstaller(List<int>? bundled, List<int> standalone) {
  require(
    bundled != null &&
        bundled.isNotEmpty &&
        digest(bundled) == digest(standalone),
    'node_installer_bundle_mismatch',
  );
}

void checkIdentity(Map release, String tag, String commit) {
  require(release['draft'] == true, 'refusing_published_release');
  require(release['tag_name'] == tag, 'draft_tag_mismatch');
  require(release['target_commitish'] == commit, 'draft_commit_mismatch');
}

Future<String> git(String root, List<String> args, {String? input}) async {
  final process = await Process.start(
    'git',
    args,
    workingDirectory: root,
    environment: {'GIT_TERMINAL_PROMPT': '0', 'GCM_INTERACTIVE': 'Never'},
  );
  final out = utf8.decoder.bind(process.stdout).join();
  final err = process.stderr.drain<void>();
  if (input != null) process.stdin.write(input);
  await process.stdin.close();
  require(await process.exitCode == 0, 'git_operation_failed');
  await err;
  return (await out).trim();
}

class GitHub {
  GitHub(this.token);
  final String token;
  final client = HttpClient();

  Future<dynamic> call(
    String path, {
    String method = 'GET',
    Object? value,
    Uint8List? data,
    bool upload = false,
    bool missing = false,
  }) async {
    final uri = Uri.parse(
      'https://${upload ? 'uploads' : 'api'}.github.com/repos/$repo$path',
    );
    final request = await client
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 30));
    request.followRedirects = false;
    request.headers.set('Authorization', 'Bearer $token');
    request.headers.set('Accept', 'application/vnd.github+json');
    request.headers.set('User-Agent', 'Sky-UI-draft');
    request.headers.set('X-GitHub-Api-Version', '2022-11-28');
    if (value != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(value));
    } else if (data != null) {
      request.headers.contentType = ContentType.binary;
      request.contentLength = data.length;
      request.add(data);
    }
    final response = await request.close().timeout(const Duration(minutes: 3));
    if (missing && response.statusCode == 404) {
      await response.drain<void>();
      return null;
    }
    require(
      response.statusCode >= 200 && response.statusCode < 300,
      'github_http_${response.statusCode}',
    );
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      require(
        bytes.length + chunk.length <= 8 * 1024 * 1024,
        'github_response_too_large',
      );
      bytes.add(chunk);
    }
    return jsonDecode(utf8.decode(bytes.takeBytes()));
  }
}

Map<String, Uint8List> checkAssets(
  String root,
  String tag, {
  List<String> architectures = const ['amd64', 'arm64'],
}) {
  require(
    architectures.isNotEmpty &&
        architectures.every((a) => ['amd64', 'arm64'].contains(a)),
    'invalid_architecture',
  );
  final names = [
    for (final arch in architectures) ...[
      'sky-ui-linux-$arch.tar.gz',
      'sky-ui-linux-$arch.tar.gz.sha256',
    ],
    for (final name in standaloneInstallers.keys) ...[name, '$name.sha256'],
  ];
  final files = {
    for (final name in names)
      name: File('$root/build/releases/$tag/$name').readAsBytesSync(),
  };
  for (final name in [
    for (final arch in architectures) 'sky-ui-linux-$arch.tar.gz',
    ...standaloneInstallers.keys,
  ]) {
    final parts = utf8
        .decode(files['$name.sha256']!)
        .trim()
        .split(RegExp(r'\s+'));
    require(
      parts.length == 2 && parts[1] == name && parts[0] == digest(files[name]!),
      'local_checksum_mismatch',
    );
  }
  String normalized(List<int> data) =>
      utf8.decode(data).replaceAll('\r\n', '\n');
  for (final entry in standaloneInstallers.entries) {
    require(
      normalized(files[entry.key]!) ==
          normalized(File('$root/${entry.value}').readAsBytesSync()),
      'installer_source_mismatch',
    );
  }
  final sources = buildSources(root);
  for (final arch in architectures) {
    final members = tarSelected(
      files['sky-ui-linux-$arch.tar.gz']!,
      (_) => true,
      limit: 256 * 1024 * 1024,
    );
    checkBundledNodeInstaller(
      members[standaloneInstallers['install-server-node.sh']],
      files['install-server-node.sh']!,
    );
    require(
      normalized(members['VERSION']!).trim() == tag.substring(1) &&
          normalized(members['ARCH']!).trim() == arch &&
          normalized(members['BUILD_MODE']!).trim() == 'native-v1' &&
          normalized(members['MIN_GLIBC']!).trim() == '2.31',
      'bundle_version_mismatch',
    );
    final manifest =
        jsonDecode(normalized(members['BUILD_MANIFEST.json']!)) as Map;
    require(
      manifest['architecture'] == arch &&
          manifest['glibc'] == '2.31' &&
          jsonEncode(manifest['sources']) == jsonEncode(sources) &&
          normalized(members['SOURCE_SHA256']!).trim() ==
              digest(utf8.encode(jsonEncode(sources))),
      'native_build_source_mismatch',
    );
    final recorded = manifest['files'] as Map;
    require(
      recorded.length == members.length - 2 &&
          recorded.entries.every(
            (e) =>
                members.containsKey(e.key) &&
                digest(members[e.key]!) == e.value,
          ),
      'native_build_files_mismatch',
    );
    for (final name in [
      'bin/sky-ui',
      'bin/sky-ops',
      'bin/caddy',
      'lib/libsqlite3.so',
      'lib/libsky_posix.so',
    ]) {
      require(
        elfMatches(members[name]!, arch),
        'native_elf_architecture_mismatch',
      );
    }
    for (final entry in members.entries) {
      final name = entry.key;
      require(
        !name.endsWith('.py') &&
            !name.startsWith('source/') &&
            ![
              'deploy/build_host.sh',
              'deploy/dart_sdk.sh',
              'deploy/prepare_build.sh',
              'deploy/build_versions.sh',
            ].contains(name) &&
            !name.contains('/test/') &&
            !name.contains('/tool/'),
        'unexpected_release_member',
      );
      final local =
          name.startsWith('deploy/') || name.startsWith('compatibility/')
          ? name
          : name == 'web/styles.css' ||
                name == 'web/index.html' ||
                name.startsWith('web/fonts/')
          ? 'app/web/$name'
          : null;
      if (local != null)
        require(
          name.endsWith('.ttf')
              ? digest(File('$root/$local').readAsBytesSync()) ==
                    digest(entry.value)
              : normalized(File('$root/$local').readAsBytesSync()) ==
                    normalized(entry.value),
          'bundle_source_mismatch',
        );
    }
  }
  return files;
}

Future<void> main(List<String> args) async {
  GitHub? github;
  try {
    require(args.length == 1, 'usage_draft_release_notes_file_or_check');
    final root = File(Platform.script.toFilePath())
        .parent
        .parent
        .parent
        .parent
        .path;
    final tag = 'v${File('$root/VERSION').readAsStringSync().trim()}';
    require(
      RegExp(r'^v\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?$').hasMatch(tag),
      'invalid_version',
    );
    final checkOnly = [
      '--check',
      '--check-amd64',
      '--check-arm64',
    ].contains(args.single);
    final files = checkAssets(
      root,
      tag,
      architectures: args.single == '--check-amd64'
          ? ['amd64']
          : args.single == '--check-arm64'
          ? ['arm64']
          : ['amd64', 'arm64'],
    );
    if (checkOnly) {
      stdout.writeln(
        'PASS: $tag native assets, checksums and build-source manifests.',
      );
      return;
    }
    final notes = File(args.single).readAsStringSync();
    require(
      notes.trim().isNotEmpty && utf8.encode(notes).length <= 65536,
      'invalid_release_notes',
    );
    require(
      (await git(root, ['status', '--porcelain'])).isEmpty,
      'commit_working_tree_first',
    );
    require(
      await git(root, ['log', '-1', '--format=%s']) == tag,
      'commit_version_mismatch',
    );
    final commit = await git(root, ['rev-parse', 'HEAD']);
    final credential = await git(root, [
      'credential',
      'fill',
    ], input: 'protocol=https\nhost=github.com\n\n');
    final values = {
      for (final line in credential.split(RegExp(r'\r?\n')))
        if (line.contains('='))
          line.substring(0, line.indexOf('=')): line.substring(
            line.indexOf('=') + 1,
          ),
    };
    require(
      values['password']?.isNotEmpty == true,
      'github_credentials_missing',
    );
    github = GitHub(values['password']!);
    require(
      (await github.call('/branches/main'))['commit']['sha'] == commit,
      'push_commit_first',
    );
    // Create the real Git tag before the draft. A display name is not a tag.
    var ref = await github.call('/git/ref/tags/$tag', missing: true);
    ref ??= await github.call(
      '/git/refs',
      method: 'POST',
      value: {'ref': 'refs/tags/$tag', 'sha': commit},
    );
    require(
      ref['object']['type'] == 'commit' && ref['object']['sha'] == commit,
      'tag_commit_mismatch',
    );
    final releases = await github.call('/releases?per_page=100') as List;
    final matches = releases.where((r) => r['tag_name'] == tag).toList();
    require(matches.length <= 1, 'duplicate_release');
    final release = matches.isNotEmpty
        ? matches.single
        : await github.call(
            '/releases',
            method: 'POST',
            value: {
              'tag_name': tag,
              'target_commitish': commit,
              'name': 'Sky UI $tag',
              'draft': true,
              'prerelease': false,
              'body': notes,
            },
          );
    checkIdentity(release, tag, commit);
    final id = release['id'] as int;
    for (final name in assetNames) {
      final present = (release['assets'] as List)
          .where((a) => a['name'] == name)
          .toList();
      require(present.length <= 1, 'duplicate_asset');
      final asset = present.isNotEmpty
          ? present.single
          : await github.call(
              '/releases/$id/assets?name=${Uri.encodeQueryComponent(name)}',
              method: 'POST',
              data: files[name],
              upload: true,
            );
      require(
        asset['state'] == 'uploaded' &&
            asset['size'] == files[name]!.length &&
            asset['digest'] == 'sha256:${digest(files[name]!)}',
        'uploaded_asset_mismatch',
      );
      stdout.writeln('Verified asset: $name');
    }
    final result = await github.call('/releases/$id');
    checkIdentity(result, tag, commit);
    final assets = result['assets'] as List;
    require(
      assets.length == assetNames.length &&
          assets.every((a) => assetNames.contains(a['name'])),
      'unexpected_release_assets',
    );
    stdout.writeln(
      jsonEncode({
        'url': result['html_url'],
        'id': id,
        'tag': result['tag_name'],
        'draft': result['draft'],
        'commit': commit,
      }),
    );
  } on Object catch (error) {
    // Never print credential-helper output, request headers or server error bodies.
    stderr.writeln(
      error is OpsError ? error.code : 'draft_failed_${error.runtimeType}',
    );
    exitCode = 1;
  } finally {
    github?.client.close(force: true);
  }
}
