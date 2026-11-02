import 'dart:io';
import 'dart:convert';

import 'host.dart';
import 'artifacts.dart';

final releasePattern = RegExp(
  r'^\d+\.\d+\.\d+(?:-[A-Za-z0-9.]+)?-(?:amd64|arm64)$',
);
final slotPattern = RegExp(r'^(?:v\d+\.\d+\.\d+|imported)-[0-9a-f]{16}$');
final logPattern = RegExp(r'^(?:update|maintenance)-([0-9a-f]{32})\.log$');
final managedTemporaryPattern = RegExp(
  r'^sky-ui-(?:install\.[A-Za-z0-9]{8}|build(?:\.[A-Za-z0-9]{8}|-[A-Za-z0-9]{6}))$',
);

class Retention {
  Retention({
    this.releaseRoot = releases,
    this.proc = '/proc',
    this.temporaryRoot = '/var/tmp',
  });
  final String releaseRoot, proc, temporaryRoot;
  final removed = <String>[];
  Map<String, dynamic> read(String path) {
    if (!exists(path)) return {};
    host.trusted(path);
    return readJson(path);
  }

  String? target(String link) {
    if (!isLink(link)) return null;
    final path = resolved(link);
    host.trusted(path, directory: true);
    return path;
  }

  void record(String root, String selected, String? previous) {
    host.trusted(root, directory: true);
    final old = read('$root/retention.json');
    if (previous == selected)
      previous = old['current'] == selected ? old['previous'] as String? : null;
    if (previous != null) {
      final legacy =
          parent(root) == cores &&
          basename(previous) == 'bin' &&
          parent(parent(previous)) == releaseRoot;
      require(
        (parent(previous) == root || legacy) && !isLink(previous),
        'unsafe_retention_path',
      );
      host.trusted(previous, directory: true);
    }
    atomicJson('$root/retention.json', {
      'current': selected,
      'previous': previous,
    }, mode: 0x180);
  }

  void recordPanel(String? previous) {
    final selected = target(current);
    require(
      selected != null && parent(selected) == releaseRoot,
      'unsafe_retention_path',
    );
    record(releaseRoot, selected!, previous);
  }

  void recordCore(String core, String? previous) {
    final root = '$cores/$core', selected = target('$cores/$core/current');
    if (selected != null && parent(selected) == root)
      record(root, selected, previous);
  }

  List<String> references() {
    final refs = <String>[];
    if (!Directory(proc).existsSync()) return refs;
    for (final process in Directory(proc).listSync(followLinks: false)) {
      if (!RegExp(r'^[0-9]+$').hasMatch(basename(process.path))) continue;
      try {
        for (final name in ['exe', 'cwd']) {
          try {
            refs.add(Link('${process.path}/$name').targetSync());
          } on FileSystemException catch (e) {
            if (e.osError?.errorCode == 13) rethrow;
          }
        }
        refs.addAll(
          utf8
              .decode(
                File('${process.path}/cmdline').readAsBytesSync(),
                allowMalformed: true,
              )
              .split('\x00'),
        );
        for (final line
            in utf8
                .decode(
                  File('${process.path}/maps').readAsBytesSync(),
                  allowMalformed: true,
                )
                .split('\n')) {
          final match = RegExp(r'^(?:\S+\s+){5}(.*)$').firstMatch(line);
          if (match != null) refs.add(match[1]!);
        }
        for (final fd in Directory(
          '${process.path}/fd',
        ).listSync(followLinks: false)) {
          try {
            refs.add(Link(fd.path).targetSync());
          } on FileSystemException catch (e) {
            if (e.osError?.errorCode == 13) rethrow;
          }
        }
      } on FileSystemException catch (e) {
        if (e.osError?.errorCode == 13) rethrow;
      }
    }
    return refs;
  }

  void remove(String path, String root) {
    require(
      parent(path) == root && !isLink(path) && resolved(path) == path,
      'unsafe_retention_path',
    );
    final directory = Directory(path).existsSync();
    host.trusted(path, directory: directory);
    if (directory)
      host.deleteTree(path);
    else
      unlink(path);
    removed.add(path);
  }

  void pruneVersions(
    String root,
    String? selected,
    RegExp pattern,
    List<String> refs, {
    bool panel = false,
  }) {
    host.trusted(root, directory: true);
    final candidates = Directory(root)
        .listSync(followLinks: false)
        .whereType<Directory>()
        .map((d) => d.path)
        .where((p) => pattern.hasMatch(basename(p)))
        .toList();
    final keep = <String>{if (selected != null) selected};
    final history = read('$root/retention.json');
    if (selected != null && history['current'] == selected) {
      final previous = history['previous'] as String?;
      if (previous != null) {
        final legacy =
            parent(root) == cores &&
            basename(previous) == 'bin' &&
            parent(parent(previous)) == releaseRoot;
        require(parent(previous) == root || legacy, 'unsafe_retention_path');
        if (exists(previous)) keep.add(previous);
        if (legacy) refs.add(previous);
      }
    } else if (selected != null) {
      final older =
          candidates
              .where(
                (p) =>
                    p != selected &&
                    (!panel ||
                        compareVersions(
                              basename(p)
                                  .replaceFirst(RegExp(r'-(amd64|arm64)$'), ''),
                              basename(selected)
                                  .replaceFirst(RegExp(r'-(amd64|arm64)$'), ''),
                            ) <
                            0),
              )
              .toList()
            ..sort(
              (a, b) =>
                  FileStat.statSync(b).modified
                      .compareTo(FileStat.statSync(a).modified),
            );
      if (older.isNotEmpty) keep.add(older.first);
    }
    for (final p in candidates)
      if (!keep.contains(p) && !refs.any((r) => within(r, p))) remove(p, root);
  }

  void pruneFiles(DateTime clock) {
    final result = read('$state/result.json'), logs = '$state/logs';
    if (exists(logs)) {
      host.trusted(logs, directory: true);
      final files =
          Directory(logs)
              .listSync(followLinks: false)
              .whereType<File>()
              .map((f) => f.path)
              .where((p) => logPattern.hasMatch(basename(p)))
              .toList()
            ..sort(
              (a, b) =>
                  FileStat.statSync(b).modified
                      .compareTo(FileStat.statSync(a).modified),
            );
      final currentLogs = files
          .where((p) => logPattern.firstMatch(basename(p))![1] == result['id'])
          .toSet();
      final keep = {
        ...currentLogs,
        ...files
            .where((p) => !currentLogs.contains(p))
            .take(currentLogs.isEmpty ? 20 : 19),
      };
      for (final p in files)
        if (!currentLogs.contains(p) &&
            (!keep.contains(p) ||
                clock.difference(FileStat.statSync(p).modified).inDays >= 14))
          remove(p, logs);
    }
    const backups = '$state/backups';
    if (exists(backups)) {
      final rescue =
          Directory(backups)
              .listSync(followLinks: false)
              .whereType<File>()
              .map((f) => f.path)
              .where(
                (p) =>
                    RegExp(r'^[a-f0-9]{32}\.json$').hasMatch(basename(p)) &&
                    read(p)['purpose'] == 'rescue',
              )
              .toList()
            ..sort(
              (a, b) =>
                  FileStat.statSync(b).modified
                      .compareTo(FileStat.statSync(a).modified),
            );
      for (final p in rescue.skip(1)) {
        final archive = p.replaceFirst(RegExp(r'\.json$'), '.tar.gz');
        if (exists(archive)) remove(archive, backups);
        remove(p, backups);
      }
    }
    const work = '$state/work';
    if (exists(work)) {
      host.trusted(work, directory: true);
      for (final item in Directory(work).listSync(followLinks: false))
        if (!isLink(item.path) &&
            RegExp(r'^(?:tmp|panel-update-|prepare\.)[A-Za-z0-9_.-]+$')
                .hasMatch(basename(item.path)) &&
            clock.difference(item.statSync().modified).inDays >= 1)
          remove(item.path, work);
    }
  }

  Map<String, dynamic> clean() {
    host.trusted(state, directory: true);
    if (Directory(state)
            .listSync(followLinks: false)
            .any(
              (p) =>
                  basename(p.path).endsWith('intent.json') &&
                  basename(p.path) != 'cleanup-intent.json',
            ) ||
        exists('$state/inbox/request.json') ||
        ['queued', 'running'].contains(read('$state/result.json')['status']))
      return {'skipped': 'busy'};
    final panel = target(current);
    require(
      panel != null &&
          parent(panel) == releaseRoot &&
          releasePattern.hasMatch(basename(panel)),
      'unsafe_retention_path',
    );
    final refs = references();
    for (final core in engineIds) {
      final root = '$cores/$core';
      if (!exists(root)) continue;
      final selected = target('$root/current');
      if (selected != null) {
        require(
          parent(selected) == root ||
              basename(selected) == 'bin' &&
                  parent(parent(selected)) == releaseRoot,
          'unsafe_retention_path',
        );
        refs.add(selected);
      }
      pruneVersions(root, selected, slotPattern, refs);
    }
    pruneVersions(releaseRoot, panel, releasePattern, refs, panel: true);
    pruneFiles(DateTime.now());
    if (exists(temporaryRoot))
      for (final dir in Directory(
        temporaryRoot,
      ).listSync(followLinks: false).whereType<Directory>())
        if (managedTemporaryPattern.hasMatch(basename(dir.path)) &&
            DateTime.now().difference(dir.statSync().modified).inDays >= 1 &&
            !refs.any((r) => within(r, dir.path))) {
          if (rootOwnedDirectory(dir.path)) remove(dir.path, temporaryRoot);
        }
    return {'removed': removed.length};
  }
}

void recordRetention(String kind, String? previous, [String? core]) {
  try {
    final r = Retention();
    if (kind == 'panel')
      r.recordPanel(previous);
    else
      r.recordCore(core!, previous);
  } on Object {
    stdout.writeln('Sky UI: retention metadata could not be updated.');
  }
}
