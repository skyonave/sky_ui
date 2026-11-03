import 'dart:io';

const packages = {
  'sky_ui_api': 'api',
  'sky_ui_web': 'web',
  'sky_ui_ops': 'ops',
  'sky_ui_shared': 'shared',
};

/// Dependency rules for production code. No SDK/package downloads are needed.
List<String> checkArchitecture(Directory root) {
  final files = <String, File>{};
  final errors = <String>[];
  final base = root.absolute.uri.path;
  String relative(Uri uri) => uri.path.startsWith(base)
      ? uri.path.substring(base.length)
      : uri.toString();
  for (final package in packages.values) {
    for (final area in ['lib', 'bin', if (package == 'web') 'web']) {
      final directory = Directory.fromUri(
        root.uri.resolve('app/$package/$area/'),
      );
      if (!directory.existsSync()) continue;
      for (final file in directory.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (file is File && file.path.endsWith('.dart')) {
          files[relative(file.absolute.uri)] = file;
        }
      }
    }
  }
  final graph = <String, Set<String>>{};
  final directives = RegExp(
    r'''^\s*(?:import|export|part)\s+(['"][\s\S]*?);''',
    multiLine: true,
  );
  final uris = RegExp(r'''['"]([^'"]+)['"]''');
  for (final entry in files.entries) {
    final from = entry.key;
    final package = from.split('/')[1];
    final edges = graph[from] = <String>{};
    final targets = directives
        .allMatches(entry.value.readAsStringSync())
        .expand((directive) => uris.allMatches(directive[1]!));
    for (final match in targets) {
      final uri = Uri.parse(match[1]!);
      String? to;
      if (uri.scheme == 'package') {
        final target = packages[uri.pathSegments.first];
        if (target != null) {
          to = 'app/$target/lib/${uri.pathSegments.skip(1).join('/')}';
        } else if (package == 'shared') {
          errors.add(
            '$from: shared models cannot depend on ${uri.pathSegments.first}.',
          );
        }
      } else if (uri.scheme.isEmpty) {
        to = relative(entry.value.absolute.uri.resolveUri(uri));
      } else if (package == 'shared' &&
          !{
            'dart:core',
            'dart:collection',
            'dart:convert',
            'dart:math',
            'dart:async',
            'dart:typed_data',
          }.contains(uri.toString())) {
        errors.add(
          '$from: shared models must stay portable (${uri.toString()}).',
        );
      }
      if (to == null) continue;
      if (!files.containsKey(to)) {
        errors.add('$from: missing production dependency $to.');
        continue;
      }
      edges.add(to);
      final targetPackage = to.split('/')[1];
      if (targetPackage != package && targetPackage != 'shared') {
        errors.add('$from: $package cannot import $targetPackage.');
      }
      if (package == 'shared' && targetPackage != 'shared') {
        errors.add('$from: shared cannot import applications.');
      }
      if (package == 'web') {
        if (from.contains('/src/shared/') &&
            (to.contains('/src/features/') || to.contains('/src/app/'))) {
          errors.add(
            '$from: shared UI cannot depend on features or app composition ($to).',
          );
        }
        if (from.contains('/src/features/') && to.contains('/src/app/')) {
          errors.add('$from: features cannot depend on app composition ($to).');
        }
      }
      if (package == 'api') {
        if ((from.contains('/src/application/') ||
                from.contains('/src/engines/')) &&
            (to.contains('/src/http/') || to.contains('/src/bootstrap/'))) {
          errors.add(
            '$from: use cases and engines cannot depend on HTTP/bootstrap ($to).',
          );
        }
        if (from.contains('/src/application/') &&
            to.contains('/src/infrastructure/')) {
          errors.add(
            '$from: inject an application contract instead of infrastructure ($to).',
          );
        }
        if (from.contains('/src/engines/') &&
            (to.contains('/src/application/access/panel_service.dart') ||
                to.contains(
                  '/src/application/configuration/transaction.dart',
                ) ||
                to.contains('/src/infrastructure/persistence/'))) {
          errors.add(
            '$from: adapters cannot own application transactions/persistence ($to).',
          );
        }
      }
      if (package == 'ops') {
        if (from.contains('/src/features/') &&
            (to.contains('/src/cli/') || to.contains('/src/app/'))) {
          errors.add(
            '$from: operations features cannot depend on command dispatch ($to).',
          );
        }
        if ((from.contains('/src/platform/') ||
                from.contains('/src/shared/')) &&
            (to.contains('/src/features/') ||
                to.contains('/src/cli/') ||
                to.contains('/src/app/'))) {
          errors.add(
            '$from: operations foundations cannot depend on features ($to).',
          );
        }
      }
    }
  }
  final visited = <String>{}, active = <String>{}, path = <String>[];
  void visit(String node) {
    if (active.contains(node)) {
      errors.add(
        'Dependency cycle: ${[...path.skip(path.indexOf(node)), node].join(' -> ')}',
      );
      return;
    }
    if (!visited.add(node)) return;
    active.add(node);
    path.add(node);
    for (final dependency in graph[node] ?? <String>{}) {
      visit(dependency);
    }
    path.removeLast();
    active.remove(node);
  }

  for (final node in graph.keys) {
    visit(node);
  }
  return errors;
}

void main() {
  final root = File.fromUri(Platform.script).parent.parent;
  final errors = checkArchitecture(root);
  if (errors.isNotEmpty) {
    stderr.writeln(errors.join('\n'));
    exitCode = 1;
  } else {
    stdout.writeln('Architecture boundaries and dependency graph passed.');
  }
}
