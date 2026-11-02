import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'host.dart';

bool safeMember(String path) =>
    path.isNotEmpty &&
    !path.startsWith('/') &&
    !path.contains('\\') &&
    !path.contains('\x00') &&
    path.split('/').every((p) => p.isNotEmpty && p != '.' && p != '..');

// For already checksum-verified upstream artifacts, retain only needed members.
// Backup parsing keeps its independent bound on the full gzip expansion below.
Map<String, Uint8List> tarSelected(
  List<int> bytes,
  bool Function(String) select, {
  int limit = 256 * 1024 * 1024,
  int maxFiles = 20000,
}) {
  final result = <String, Uint8List>{}, names = <String>{};
  var total = 0;
  TarDecoder().decodeStream(
    GZipDecoder().decodeLazy(InputMemoryStream(bytes), verify: true),
    verify: true,
    keepEntries: false,
    callback: (entry) {
      var name = entry.name;
      if (name.startsWith('./')) name = name.substring(2);
      if (name.endsWith('/')) name = name.substring(0, name.length - 1);
      if (name.isEmpty && entry.isDirectory) return;
      require(
        safeMember(name) &&
            !entry.isSymbolicLink &&
            names.add(name) &&
            names.length <= maxFiles &&
            (entry.mode & 0xf000 == 0 ||
                entry.mode & 0xf000 == (entry.isDirectory ? 0x4000 : 0x8000)),
        'archive_invalid',
      );
      if (entry.isDirectory) return;
      total += entry.size;
      require(
        entry.isFile && entry.size >= 0 && total <= limit,
        'archive_too_large',
      );
      if (select(name)) {
        result[name] = entry.readBytes()!;
        require(result[name]!.length == entry.size, 'archive_invalid');
      }
    },
  );
  return result;
}

Map<String, Uint8List> tarFiles(
  List<int> bytes, {
  int limit = 128 * 1024 * 1024,
  int maxFiles = 2048,
  bool directories = false,
}) {
  final output = OutputMemoryStream();
  require(
    GZipDecoder().decodeStream(
      InputMemoryStream(bytes),
      output,
      verify: true,
      maxOutputSize: limit + maxFiles * 2048 + 1024,
    ),
    'archive_invalid',
  );
  final result = <String, Uint8List>{}, names = <String>{};
  var total = 0;
  TarDecoder().decodeBytes(
    output.getBytes(),
    verify: true,
    keepEntries: false,
    callback: (entry) {
      var name = entry.name;
      if (directories) {
        if (name.startsWith('./')) name = name.substring(2);
        if (name.endsWith('/')) name = name.substring(0, name.length - 1);
        if (name.isEmpty && entry.isDirectory) return;
      }
      require(
        safeMember(name) &&
            !entry.isSymbolicLink &&
            (entry.isFile || directories && entry.isDirectory) &&
            names.add(name) &&
            names.length <= maxFiles,
        'archive_invalid',
      );
      if (entry.isDirectory) return;
      total += entry.size;
      require(entry.size >= 0 && total <= limit, 'archive_too_large');
      // Reject hard links and devices even when a decoder represents them as files.
      require(
        entry.mode & 0xf000 == 0 || entry.mode & 0xf000 == 0x8000,
        'archive_invalid',
      );
      result[name] = Uint8List.fromList(entry.readBytes()!);
      require(result[name]!.length == entry.size, 'archive_invalid');
    },
  );
  return result;
}

Uint8List packTar(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    require(safeMember(entry.key), 'archive_invalid');
    archive.add(
      ArchiveFile(entry.key, entry.value.length, entry.value)..mode = 0x180,
    );
  }
  return Uint8List.fromList(
    GZipEncoder().encodeBytes(TarEncoder().encode(archive)),
  );
}

bool validBackupMember(String name) {
  if (!safeMember(name)) return false;
  if ([
    'data/panel.sqlite',
    'data/owner.sqlite',
    'data/instances/primary.json',
    'data/cores/mihomo/config.yaml',
    for (final core in engineIds.skip(1)) ...[
      'data/instances/$core.json',
      'data/cores/$core/config.json',
    ],
  ].contains(name))
    return true;
  if (name.startsWith('etc/') && name.split('/').length == 2)
    return [
      'server.env',
      'owner.seed',
      'admin.hash',
      'gateway.secret',
      'controller.secret',
      'Caddyfile',
      'access.conf',
      'managed-by-sky-ui',
    ].contains(basename(name));
  return name.startsWith('edge/data/') &&
      name.split('/').every((p) => RegExp(r'^[A-Za-z0-9_.@+-]+$').hasMatch(p));
}

({Uint8List bytes, Map<String, dynamic> manifest}) packBackup(
  Map<String, List<int>> files,
  Map<String, dynamic> metadata,
) {
  require(
    files.length <= 2048 &&
        files.values.fold<int>(0, (n, v) => n + v.length) <= 128 * 1024 * 1024,
    'backup_too_large',
  );
  require(files.keys.every(validBackupMember), 'backup_path_invalid');
  final manifest = {
    ...metadata,
    'format': 1,
    'files': {
      for (final entry in files.entries)
        entry.key: {'sha256': digest(entry.value), 'size': entry.value.length},
    },
  };
  final manifestBytes = utf8.encode(jsonEncode(manifest));
  require(
    files.values.fold<int>(manifestBytes.length, (n, v) => n + v.length) <=
        128 * 1024 * 1024,
    'backup_too_large',
  );
  return (
    bytes: packTar({...files, 'manifest.json': manifestBytes}),
    manifest: manifest,
  );
}

({Map<String, Uint8List> files, Map<String, dynamic> manifest}) unpackBackup(
  List<int> bytes, {
  bool complete = true,
}) {
  require(bytes.length <= 128 * 1024 * 1024, 'backup_too_large');
  final files = tarFiles(bytes);
  final manifest = object(
    jsonDecode(utf8.decode(files.remove('manifest.json')!)),
  );
  final declared = object(manifest['files']);
  require(
    manifest['format'] == 1 &&
        declared.length == files.length &&
        files.keys.every(
          (k) => validBackupMember(k) && declared.containsKey(k),
        ),
    'backup_invalid',
  );
  for (final item in files.entries) {
    final d = object(declared[item.key]);
    require(
      d.length == 2 &&
          d['sha256'] == digest(item.value) &&
          d['size'] == item.value.length,
      'backup_checksum_failed',
    );
  }
  require(
    !complete ||
        {
          'data/panel.sqlite',
          'data/owner.sqlite',
          'etc/server.env',
          'etc/gateway.secret',
          'etc/controller.secret',
          'etc/Caddyfile',
          'data/cores/mihomo/config.yaml',
        }.every(files.containsKey),
    'backup_incomplete',
  );
  return (files: files, manifest: manifest);
}
