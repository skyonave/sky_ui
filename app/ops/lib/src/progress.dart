import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'host.dart';

const stages = [
  'discovery',
  'download',
  'verify',
  'backup',
  'prepare',
  'toolchain',
  'build',
  'validate',
  'install',
  'activate',
  'health',
  'rollback',
  'complete',
];

class Reporter {
  Reporter(
    this.result,
    String? currentVersion,
    String target,
    this.gid, {
    this.output = '$state/result.json',
  }) {
    progress = {
      'currentVersion': currentVersion,
      'targetVersion': target.replaceFirst(RegExp(r'^v'), ''),
      'stage': 'discovery',
      'startedAt': now(),
      'updatedAt': now(),
    };
    result['progress'] = progress;
  }
  final Map<String, dynamic> result;
  final int gid;
  final String output;
  late final Map<String, dynamic> progress;
  DateTime lastWrite = DateTime.fromMillisecondsSinceEpoch(0);
  void save() {
    progress['updatedAt'] = now();
    atomicJson(output, result, gid: gid, uid: host.uid());
    lastWrite = DateTime.now();
  }

  void stage(String name, [Map<String, dynamic> values = const {}]) {
    require(stages.contains(name), 'stage_invalid');
    progress.addAll({'stage': name, ...values});
    save();
  }

  void transfer(
    int received,
    int? total,
    String artifact, [
    String name = 'download',
  ]) {
    total ??= progress['bytesTotal'] as int?;
    progress.addAll({
      'stage': name,
      'bytesReceived': received,
      'bytesTotal': total,
      'artifact': artifact,
    });
    if (DateTime.now().difference(lastWrite).inMilliseconds >= 250 ||
        received == total)
      save();
  }

  void failed(String code, [Map<String, dynamic> values = const {}]) {
    progress.addAll({
      'errorCode': RegExp(r'^[a-z][a-z0-9_]{0,95}$').hasMatch(code)
          ? code
          : 'panel_update_failed',
      'finishedAt': now(),
      ...values,
    });
    save();
  }
}

class InstallerFailure extends OpsError {
  const InstallerFailure(this.exitCode, {String? reason})
    : super(reason ?? 'installer_failed');
  final int exitCode;
}

Future<void> runInstaller(
  List<String> args,
  Reporter reporter, {
  Duration timeout = const Duration(minutes: 30),
  Map<String, String>? extraEnvironment,
  HostLock? installLock,
}) async {
  final directory = '${parent(reporter.output)}/logs';
  host.mkdir(directory, mode: 0x1c0, uid: host.uid());
  host.trusted(directory, directory: true, uid: host.uid());
  final prefix = reporter.result['action'] == 'panel-update'
      ? 'update'
      : 'maintenance';
  final log = '$directory/$prefix-${reporter.result['id']}.log';
  // setsid gives timeout/cancellation ownership of the complete compiler tree.
  final spawn = host.native
      .lookupFunction<
        Int Function(
          Pointer<Pointer<Utf8>>,
          Pointer<Pointer<Utf8>>,
          Int,
          Pointer<Int>,
        ),
        int Function(
          Pointer<Pointer<Utf8>>,
          Pointer<Pointer<Utf8>>,
          int,
          Pointer<Int>,
        )
      >('sky_spawn');
  final poll = host.native.lookupFunction<Int Function(Int), int Function(int)>(
    'sky_poll',
  );
  final kill = host.native.lookupFunction<Int Function(Int), int Function(int)>(
    'sky_kill',
  );
  final read = host.native
      .lookupFunction<
        Int64 Function(Int, Pointer<Uint8>, Int64),
        int Function(int, Pointer<Uint8>, int)
      >('sky_read');
  final allocations = <Pointer<Utf8>>[];
  Pointer<Pointer<Utf8>> strings(List<String> values) {
    final p = calloc<Pointer<Utf8>>(values.length + 1);
    for (var i = 0; i < values.length; i++) {
      final s = values[i].toNativeUtf8();
      allocations.add(s);
      p[i] = s;
    }
    return p;
  }

  // Dart's process reaper may consume an unknown native child's wait status.
  // A shell supervisor waits for the actual command and sends its exit code on
  // a separate pipe, without interpreting any command arguments as shell code.
  final argv = strings([
        '/usr/bin/setsid',
        '/bin/bash',
        '-c',
        r'"$@"; result=$?; printf "%s\n" "$result" >&10; exit "$result"',
        'sky-ui-exec',
        ...args,
      ]),
      env = strings(
        {
          ...cleanEnvironment,
          ...?extraEnvironment,
          if (installLock != null) 'SKY_UI_TRANSACTION_LOCK_FD': '9',
        }.entries.map((e) => '${e.key}=${e.value}').toList(),
      );
  final handles = calloc<Int>(3);
  var pid = -1, fd = -1, statusFd = -1, exited = false, complete = false;
  final buffer = calloc<Uint8>(65536);
  final output = <int>[];
  var pending = '';
  String? failureReason;
  void chunk(List<int> bytes) {
    output.addAll(bytes);
    if (output.length > 262144) output.removeRange(0, output.length - 262144);
    pending += utf8.decode(bytes, allowMalformed: true);
    if (pending.length > 65536)
      pending = pending.substring(pending.length - 65536);
    while (pending.contains('\n')) {
      final split = pending.indexOf('\n'), line = pending.substring(0, split);
      pending = pending.substring(split + 1);
      if (line.startsWith('SKY_UI_STAGE=') &&
          stages.contains(line.substring(13))) {
        final name = line.substring(13);
        reporter.stage(name, {
          'bytesReceived': null,
          'bytesTotal': null,
          'artifact': name == 'toolchain' ? 'Dart SDK' : null,
        });
      }
      // Only explicit public reason codes may leave the private installer log.
      if (line == 'SKY_UI_ERROR=native_binary_incompatible')
        failureReason = 'native_binary_incompatible';
    }
  }

  try {
    require(
      spawn(argv, env, installLock?.fd ?? -1, handles) == 0,
      'command_failed',
    );
    pid = handles[0];
    fd = handles[1];
    statusFd = handles[2];
    final end = DateTime.now().add(timeout);
    var code = -1, eof = false;
    var statusText = '';
    while (!exited || !eof) {
      for (var reads = 0; reads < 16; reads++) {
        final n = read(fd, buffer, 65536);
        if (n > 0)
          chunk(buffer.asTypedList(n));
        else {
          if (n == 0) eof = true;
          break;
        }
      }
      if (!exited) {
        final n = read(statusFd, buffer, 64);
        if (n > 0) {
          statusText += ascii.decode(buffer.asTypedList(n));
          require(statusText.length <= 8, 'command_failed');
        }
        if (statusText.endsWith('\n')) {
          code = int.parse(statusText.trim());
          require(code >= 0 && code <= 255, 'command_failed');
          exited = true;
        } else if (n == 0) {
          final observed = poll(pid);
          code = observed >= 0 ? observed : 1;
          exited = true;
        }
      }
      if (DateTime.now().isAfter(end)) throw const InstallerFailure(124);
      if (!exited || !eof) await sleep(50);
    }
    if (code != 0) throw InstallerFailure(code, reason: failureReason);
    complete = true;
  } finally {
    if (pid >= 0 && !complete) {
      kill(pid);
      if (!exited) while (poll(pid) == -1) await sleep(50);
    }
    if (pid >= 0) poll(pid);
    if (fd >= 0) host.close(fd);
    if (statusFd >= 0) host.close(statusFd);
    for (final p in allocations) calloc.free(p);
    calloc.free(argv);
    calloc.free(env);
    calloc.free(handles);
    calloc.free(buffer);
    host.atomic(log, output, mode: 0x180, uid: host.uid());
  }
}
