import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

const state = '/var/lib/sky-ui-maintenance';
const dataRoot = '/var/lib/sky-ui';
const etc = '/etc/sky-ui';
const edge = '/var/lib/sky-ui-edge';
const cores = '/opt/sky-ui/cores';
const current = '/opt/sky-ui/current';
const releases = '/opt/sky-ui/releases';
const downloadCache = '/var/cache/sky-ui-install';
const downloadCacheMarker = 'sky-ui-download-cache-v1';
const engineIds = ['mihomo', 'sing-box', 'xray', 'amneziawg'];
const units = [
  'sky-ui.service',
  'sky-ui-mihomo.service',
  'sky-ui-sing-box.service',
  'sky-ui-xray.service',
  'sky-ui-amneziawg.service',
  'sky-ui-edge.service',
];
const allUnits = [
  ...units,
  'sky-ui-certificates.service',
  'sky-ui-certificates.timer',
  'sky-ui-maintenance.service',
  'sky-ui-maintenance-recovery.service',
  'sky-ui-update.service',
  'sky-ui-update-recovery.service',
  'sky-ui-cleanup.service',
  'sky-ui-cleanup.timer',
];
final identityPattern = RegExp(r'^[a-f0-9]{32}$');
final coreTagPattern = RegExp(r'^v[0-9]+\.[0-9]+\.[0-9]+$');

class OpsError implements Exception {
  const OpsError(this.code);
  final String code;
  @override
  String toString() => code;
}

class CommandFailure extends OpsError {
  const CommandFailure(this.tool, this.exitCode, this.diagnostic)
    : super('command_failed');
  final String tool;
  final int exitCode;
  final String? diagnostic;
}

void require(bool condition, String code) {
  if (!condition) throw OpsError(code);
}

String digest(List<int> bytes) => sha256.convert(bytes).toString();
String randomId([int count = 16]) => List.generate(
  count,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();
String now() => DateTime.now().toUtc().toIso8601String();
bool exists(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) !=
    FileSystemEntityType.notFound;
bool isLink(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false) ==
    FileSystemEntityType.link;
String resolved(String path) => Directory(path).resolveSymbolicLinksSync();
String basename(String path) => path.split('/').last;
String parent(String path) => path.substring(0, path.lastIndexOf('/')).isEmpty
    ? '/'
    : path.substring(0, path.lastIndexOf('/'));
bool within(String child, String root) =>
    child == root || child.startsWith('$root/');
Map<String, dynamic> object(Object? value) =>
    Map<String, dynamic>.from(value as Map);
Map<String, dynamic> readJson(String path, [int limit = 16384]) =>
    object(jsonDecode(utf8.decode(host.read(path, limit: limit))));
String readText(String path, [int limit = 16384]) =>
    utf8.decode(host.read(path, limit: limit));
final host = Host();
bool rootOwnedDirectory(String path) {
  try {
    host.trusted(path, directory: true);
    return true;
  } on OpsError {
    return false;
  }
}

class Host {
  late final DynamicLibrary native = DynamicLibrary.open(
    Platform.environment['SKY_UI_POSIX_LIBRARY'] ??
        '${parent(parent(Platform.resolvedExecutable))}/lib/libsky_posix.so',
  );
  late final uid = native.lookupFunction<Int Function(), int Function()>(
    'sky_uid',
  );
  late final gid = native.lookupFunction<Int Function(), int Function()>(
    'sky_gid',
  );
  late final close = native
      .lookupFunction<Int Function(Int), int Function(int)>('sky_close');
  late final sync = native.lookupFunction<Int Function(Int), int Function(int)>(
    'sky_sync',
  );
  late final lock = native
      .lookupFunction<Int Function(Int, Int), int Function(int, int)>(
        'sky_lock',
      );
  late final mode = native
      .lookupFunction<Int Function(Int, Int), int Function(int, int)>(
        'sky_mode',
      );
  late final owner = native
      .lookupFunction<Int Function(Int, Int, Int), int Function(int, int, int)>(
        'sky_owner',
      );
  late final umask = native
      .lookupFunction<Int Function(Int), int Function(int)>('sky_umask');
  late final _metadata = native
      .lookupFunction<
        Int Function(Int, Pointer<Int64>),
        int Function(int, Pointer<Int64>)
      >('sky_metadata');
  late final _read = native
      .lookupFunction<
        Int64 Function(Int, Pointer<Uint8>, Int64),
        int Function(int, Pointer<Uint8>, int)
      >('sky_read');
  late final _write = native
      .lookupFunction<
        Int64 Function(Int, Pointer<Uint8>, Int64),
        int Function(int, Pointer<Uint8>, int)
      >('sky_write');
  late final _create = native
      .lookupFunction<
        Int Function(Int, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>)
      >('sky_create');
  late final _replace = native
      .lookupFunction<
        Int Function(Int, Pointer<Utf8>, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>, Pointer<Utf8>)
      >('sky_replace');
  late final _unlink = native
      .lookupFunction<
        Int Function(Int, Pointer<Utf8>),
        int Function(int, Pointer<Utf8>)
      >('sky_unlink');
  int pathCall(String symbol, String path) {
    require(
      path.startsWith('/') &&
          !path.split('/').any((x) => x == '.' || x == '..') &&
          !path.contains('\x00'),
      'unsafe_file',
    );
    final name = path.toNativeUtf8();
    try {
      return native.lookupFunction<
        Int Function(Pointer<Utf8>),
        int Function(Pointer<Utf8>)
      >(symbol)(name);
    } finally {
      calloc.free(name);
    }
  }

  List<int> metadata(int fd) {
    final out = calloc<Int64>(9);
    try {
      require(_metadata(fd, out) == 0, 'unsafe_file');
      return List.generate(9, (i) => out[i]);
    } finally {
      calloc.free(out);
    }
  }

  int open(String path, [String kind = 'read']) {
    final fd = pathCall('sky_open_$kind', path);
    require(fd >= 0, 'unsafe_file');
    return fd;
  }

  Uint8List read(String path, {int limit = 128 * 1024 * 1024, int? uid}) {
    final fd = open(path);
    final chunk = calloc<Uint8>(65536);
    try {
      final before = metadata(fd);
      require(
        before[0] & 0xf000 == 0x8000 &&
            before[3] == 1 &&
            before[4] <= limit &&
            (uid == null || before[1] == uid),
        'unsafe_file',
      );
      final out = BytesBuilder(copy: false);
      while (true) {
        final size = _read(fd, chunk, min(65536, limit + 1 - out.length));
        require(size >= 0, 'unsafe_file');
        if (size == 0) break;
        out.add(Uint8List.fromList(chunk.asTypedList(size)));
        require(out.length <= limit, 'file_too_large');
      }
      final after = metadata(fd);
      require(
        before[4] == after[4] &&
            before[5] == after[5] &&
            before[6] == after[6] &&
            after[3] == 1,
        'file_changed',
      );
      return out.takeBytes();
    } finally {
      calloc.free(chunk);
      close(fd);
    }
  }

  void trusted(
    String path, {
    bool directory = false,
    int uid = 0,
    bool writable = false,
  }) {
    final fd = open(path, directory ? 'dir' : 'read');
    try {
      final stat = metadata(fd);
      require(
        stat[1] == uid &&
            (writable || stat[0] & 0x12 == 0) &&
            (directory
                ? stat[0] & 0xf000 == 0x4000
                : stat[0] & 0xf000 == 0x8000 && stat[3] == 1),
        'unsafe_file',
      );
    } finally {
      close(fd);
    }
  }

  void atomic(
    String path,
    List<int> bytes, {
    int mode = 0x1a0,
    int uid = 0,
    int? gid,
  }) {
    final fd = open(parent(path), 'dir'), temporary = '.sky-${randomId()}';
    final tmp = temporary.toNativeUtf8(), name = basename(path).toNativeUtf8();
    var output = -1;
    final buffer = calloc<Uint8>(max(1, bytes.length));
    try {
      output = _create(fd, tmp);
      require(output >= 0, 'unsafe_file');
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var offset = 0;
      while (offset < bytes.length) {
        final n = _write(output, buffer + offset, bytes.length - offset);
        require(n > 0, 'write_failed');
        offset += n;
      }
      require(
        sync(output) == 0 &&
            this.mode(output, mode) == 0 &&
            owner(output, uid, gid ?? this.gid()) == 0,
        'write_failed',
      );
      close(output);
      output = -1;
      require(_replace(fd, tmp, name) == 0 && sync(fd) == 0, 'write_failed');
    } finally {
      if (output >= 0) close(output);
      _unlink(fd, tmp);
      close(fd);
      calloc.free(buffer);
      calloc.free(tmp);
      calloc.free(name);
    }
  }

  void mkdir(String path, {int mode = 0x1ed, int uid = 0, int? gid}) {
    if (!exists(path)) Directory(path).createSync();
    final fd = open(path, 'dir');
    try {
      require(
        this.mode(fd, mode) == 0 && owner(fd, uid, gid ?? this.gid()) == 0,
        'unsafe_file',
      );
    } finally {
      close(fd);
    }
  }

  void deleteTree(String path) {
    require(pathCall('sky_remove_tree', path) == 0, 'cleanup_failed');
  }
}

void atomicJson(
  String path,
  Object? value, {
  int mode = 0x1a0,
  int uid = 0,
  int? gid,
}) => host.atomic(
  path,
  utf8.encode(jsonEncode(value)),
  mode: mode,
  uid: uid,
  gid: gid,
);
void unlink(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    Link(path).deleteSync();
  } else if (type != FileSystemEntityType.notFound) {
    require(type != FileSystemEntityType.directory, 'unsafe_file');
    File(path).deleteSync();
  }
}

void switchLink(String link, String target) {
  final tmp = '${parent(link)}/.next-${randomId(8)}';
  try {
    Link(tmp).createSync(target);
    Link(tmp).renameSync(link);
  } finally {
    unlink(tmp);
  }
}

Map<String, String> environment() => Map.fromEntries(
  readText('$etc/server.env')
      .split('\n')
      .where((x) => x.contains('='))
      .map(
        (x) => MapEntry(
          x.substring(0, x.indexOf('=')),
          x.substring(x.indexOf('=') + 1),
        ),
      ),
);
String panelVersion() => readText('${resolved(current)}/VERSION', 128).trim();
Map<String, String> get cleanEnvironment => {
  'PATH': '/usr/sbin:/usr/bin:/sbin:/bin',
  'HOME': '/root',
  'SAFE_PATHS': '/var/lib/sky-ui-certificates',
};
Future<ProcessResult> command(
  List<String> args, {
  bool check = true,
  Duration timeout = const Duration(seconds: 30),
  Map<String, String>? environment,
  String? input,
}) async {
  final process = await Process.start(
    args.first,
    args.skip(1).toList(),
    environment: environment ?? cleanEnvironment,
    includeParentEnvironment: false,
  );
  final out = process.stdout.fold<List<int>>([], (a, b) => a..addAll(b));
  final err = process.stderr.fold<List<int>>([], (a, b) => a..addAll(b));
  if (input != null) process.stdin.write(input);
  await process.stdin.close();
  int code;
  try {
    code = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    throw const OpsError('command_timeout');
  }
  final result = ProcessResult(
    process.pid,
    code,
    utf8.decode(await out, allowMalformed: true),
    utf8.decode(await err, allowMalformed: true),
  );
  if (check && code != 0) {
    String? diagnostic;
    if (Platform.isLinux &&
        !{
          'dart',
          'dartvm',
          'dartaotruntime',
        }.contains(basename(Platform.resolvedExecutable))) {
      try {
        require(host.uid() == 0, 'root_required');
        host.trusted(state, directory: true);
        host.mkdir('$state/logs', mode: 0x1c0);
        host.trusted('$state/logs', directory: true);
        final bytes = utf8.encode(
          '${now()}\nCommand: ${basename(args.first)}\nExit: $code\n${result.stdout}\n${result.stderr}',
        );
        diagnostic = '$state/logs/command-last.log';
        host.atomic(
          diagnostic,
          bytes.length > 262144 ? bytes.sublist(bytes.length - 262144) : bytes,
          mode: 0x180,
        );
      } on Object {
        diagnostic = null;
      }
    }
    throw CommandFailure(basename(args.first), code, diagnostic);
  }
  return result;
}

Future<String> run(
  List<String> args, {
  Duration timeout = const Duration(seconds: 30),
}) async => (await command(args, timeout: timeout)).stdout as String;
Future<bool> active(String unit) async =>
    (await command([
      'systemctl',
      'is-active',
      '--quiet',
      unit,
    ], check: false)).exitCode ==
    0;
Future<({int uid, int gid, String shell})> account(String name) async {
  final parts = (await run(['getent', 'passwd', name])).trim().split(':');
  require(parts.length == 7, 'account_invalid');
  return (uid: int.parse(parts[2]), gid: int.parse(parts[3]), shell: parts[6]);
}

Future<int> freeBytes(String path) async => int.parse(
  (await run(['df', '-B1', '--output=avail', path]))
      .trim()
      .split(RegExp(r'\s+'))
      .last,
);
Future<void> sleep([int milliseconds = 100]) =>
    Future.delayed(Duration(milliseconds: milliseconds));

class HostLock {
  HostLock(String path) : fd = host.open(path, 'lock') {
    final m = host.metadata(fd);
    require(m[1] == 0 && m[3] == 1 && m[0] & 0xf000 == 0x8000, 'unsafe_file');
  }
  final int fd;
  Future<void> acquire({Duration timeout = const Duration(seconds: 30)}) async {
    final end = DateTime.now().add(timeout);
    while (host.lock(fd, 6) != 0) {
      require(DateTime.now().isBefore(end), 'maintenance_busy');
      await sleep();
    }
  }

  void unlock() {
    require(host.lock(fd, 8) == 0, 'lock_failed');
  }

  void close() => host.close(fd);
}

Future<T> temporary<T>(
  String base,
  String prefix,
  Future<T> Function(String) work,
) async {
  final path = Directory(base).createTempSync(prefix).path;
  try {
    return await work(path);
  } finally {
    if (exists(path)) host.deleteTree(path);
  }
}

Future<Uint8List> httpBytes(
  String url,
  int limit, {
  Map<String, String> headers = const {},
  bool official = true,
  Duration timeout = const Duration(seconds: 30),
  void Function(int)? progress,
  void Function(int?)? size,
}) async {
  const allowed = {
    'raw.githubusercontent.com',
    'github.com',
    'api.github.com',
    'release-assets.githubusercontent.com',
    'objects.githubusercontent.com',
    'codeload.github.com',
    'go.dev',
    'dl.google.com',
  };
  void validate(Uri uri) => require(
    !official ||
        uri.scheme == 'https' &&
            allowed.contains(uri.host) &&
            uri.userInfo.isEmpty &&
            uri.port == 443,
    'download_invalid',
  );
  final client = HttpClient()
    ..findProxy = ((_) => 'DIRECT')
    ..connectionTimeout = timeout;
  try {
    var uri = Uri.parse(url);
    validate(uri);
    for (var redirects = 0; redirects < 6; redirects++) {
      final request = await client.getUrl(uri).timeout(timeout);
      request.followRedirects = false;
      request.headers.set('User-Agent', 'Sky-UI');
      request.headers.set('Cache-Control', 'no-cache');
      headers.forEach(request.headers.set);
      final response = await request.close().timeout(timeout);
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value('location');
        require(location != null, 'download_invalid');
        uri = uri.resolve(location!);
        validate(uri);
        continue;
      }
      require(response.statusCode == 200, 'download_failed');
      require(response.contentLength <= limit, 'download_too_large');
      size?.call(response.contentLength < 0 ? null : response.contentLength);
      final out = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        require(out.length + chunk.length <= limit, 'download_too_large');
        out.add(chunk);
        progress?.call(out.length);
      }
      return out.takeBytes();
    }
    throw const OpsError('download_invalid');
  } finally {
    client.close(force: true);
  }
}
