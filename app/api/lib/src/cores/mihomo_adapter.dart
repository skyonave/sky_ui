import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import '../config.dart';
import '../errors.dart';
import '../process_runner.dart';
import 'contracts.dart';

class MihomoAdapter implements CoreAdapter {
  MihomoAdapter(this.runner);
  final CommandRunner runner;
  String? _version;
  DateTime? _binaryModified;
  String? _binaryPath;
  WebSocket? _socket;
  HttpClient? _logClient;
  bool _connecting = false;
  bool _closed = false;
  final _entries = <CoreLogEntry>[];
  @override
  String get id => 'mihomo';
  @override
  String get name => 'mihomo';
  @override
  List<CoreLogEntry> get logs => List.unmodifiable(_entries);

  @override
  void clearLogs() => _entries.clear();

  @override
  Future<BinaryProbe> probe(ManagedCore core) async {
    final file = File(core.binary);
    if (!await file.exists()) return const BinaryProbe(false, null);
    final modified = (await file.stat()).modified;
    if (_binaryModified != modified || _binaryPath != core.binary) {
      final result = await runner.run(core.binary, [
        '-v',
      ], timeout: const Duration(seconds: 3));
      if (result.exitCode != 0) throw const ApiException('binary_probe_failed');
      _version = RegExp(
        r'\bv?\d+\.\d+\.\d+[^\s]*',
      ).firstMatch(result.output)?.group(0);
      if (_version == null) throw const ApiException('binary_probe_failed');
      _binaryModified = modified;
      _binaryPath = core.binary;
    }
    return BinaryProbe(true, _version);
  }

  @override
  Future<void> validate(ManagedCore core) async {
    if (!await File(core.binary).exists())
      throw const ApiException('binary_missing', status: 409);
    if (!await File(core.configuration).exists())
      throw const ApiException('configuration_missing', status: 409);
    final result = await runner.run(core.binary, [
      '-t',
      '-d',
      core.directory,
      '-f',
      core.configuration,
    ]);
    if (result.exitCode != 0)
      throw const ApiException('configuration_invalid', status: 422);
  }

  @override
  Future<bool> controllerReady(ManagedCore core) async {
    if (core.secret.isEmpty) return false;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    client.findProxy = (_) => 'DIRECT';
    try {
      final request = await client
          .getUrl(core.controller.resolve('/version'))
          .timeout(const Duration(seconds: 2));
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${core.secret}',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      if (response.statusCode != 200) return false;
      final body = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 2))) {
        if (body.length + chunk.length > 4096) return false;
        body.addAll(chunk);
      }
      final json = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
      return json['meta'] == true && json['version'] is String;
    } on Exception {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> observeLogs(ManagedCore core) async {
    if (_closed || _connecting || _socket != null || core.secret.isEmpty)
      return;
    _connecting = true;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    client.findProxy = (_) => 'DIRECT';
    _logClient = client;
    try {
      final socket = await WebSocket.connect(
        core.controller
            .replace(scheme: 'ws', path: '/logs', query: 'level=debug')
            .toString(),
        headers: {HttpHeaders.authorizationHeader: 'Bearer ${core.secret}'},
        customClient: client,
      ).timeout(const Duration(seconds: 3));
      if (_closed) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.pingInterval = const Duration(seconds: 20);
      socket.listen(
        (dynamic frame) {
          if (frame is! String || frame.length > 16384) return;
          try {
            final data = jsonDecode(frame) as Map<String, dynamic>;
            _entries.add(
              CoreLogEntry(
                time: DateTime.now().toUtc(),
                level: data['type'] is String ? data['type'] as String : 'info',
                message: redact(
                  data['payload'] is String ? data['payload'] as String : '',
                  [core.secret],
                ),
                source: 'core',
              ),
            );
            if (_entries.length > 200) _entries.removeAt(0);
          } on Exception {
            /* Ignore malformed controller log frames. */
          }
        },
        onError: (Object _) {
          _socket = null;
          client.close(force: true);
        },
        onDone: () {
          _socket = null;
          client.close(force: true);
        },
      );
    } on Exception {
      client.close(force: true);
      _socket = null;
    } finally {
      _connecting = false;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    await _socket?.close();
    _logClient?.close(force: true);
  }
}
