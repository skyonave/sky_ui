import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../application/access/records.dart';
import '../../infrastructure/process/command_runner.dart';
import '../../shared/api_exception.dart';
import '../contracts.dart';
import '../managed_core.dart';
import '../traffic_presence.dart';

class MihomoAdapter implements CoreAdapter, CorePresenceSource {
  MihomoAdapter(this.runner, {DateTime Function()? now})
    : _now = now ?? DateTime.now;
  final CommandRunner runner;
  final DateTime Function() _now;
  final _traffic = <String, TrafficPresence>{};
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
  Future<Map<String, RecipientPresence>> presence(
    ManagedCore core,
    PanelData data,
  ) async {
    if (core.secret.isEmpty) return {};
    final client = HttpClient()..findProxy = (_) => 'DIRECT';
    try {
      final entries = await (() async {
        final request = await client.getUrl(
          core.controller.resolve('/connections'),
        );
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${core.secret}',
        );
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) throw const FormatException();
        final body = <int>[];
        await for (final chunk in response) {
          if (body.length + chunk.length > 1024 * 1024)
            throw const FormatException();
          body.addAll(chunk);
        }
        final snapshot = jsonDecode(utf8.decode(body));
        if (snapshot is! Map || !snapshot.containsKey('connections'))
          throw const FormatException();
        final entries = snapshot['connections'];
        if (entries == null) return <dynamic>[];
        if (entries is! List) throw const FormatException();
        return entries;
      })().timeout(const Duration(seconds: 2));
      return _matchConnections(
        data,
        entries,
        _traffic.putIfAbsent(core.id, TrafficPresence.new),
      );
    } on Exception {
      return {};
    } finally {
      client.close(force: true);
    }
  }

  Map<String, RecipientPresence> _matchConnections(
    PanelData data,
    List entries,
    TrafficPresence traffic,
  ) {
    final users = <String, Map<String, String>>{};
    final isolated = <String, String>{};
    final result = <String, RecipientPresence>{};
    for (final stored in data.listeningConnections) {
      final c = stored.value, name = 'sky-ui/${c.id}';
      for (final grant in data.activeGrants(c.id)) {
        if (grant.credentials.containsKey('port')) {
          isolated['$name/${grant.id}'] = grant.id;
        } else {
          final user = switch (c.protocolId) {
            'vless' ||
            'vmess' ||
            'trojan' ||
            'anytls' ||
            'hysteria2' ||
            'shadowquic' => grant.id,
            'mieru' ||
            'trusttunnel' ||
            'http' ||
            'socks' ||
            'mixed' => grant.credentials['username'],
            'tuic' => grant.credentials['uuid'],
            _ => null,
          };
          if (user == null || user.isEmpty) continue;
          (users[name] ??= {})[user] = grant.id;
        }
        result[grant.id] = RecipientPresence.offline;
      }
    }
    final samples = <String, TrafficSample>{};
    for (final entry in entries) {
      if (entry is! Map || entry['metadata'] is! Map) return {};
      final metadata = entry['metadata'] as Map;
      final name = metadata['inboundName'];
      if (name is! String) return {};
      final inboundUsers = users[name];
      final inboundUser = metadata['inboundUser'];
      final grant = isolated[name] ?? inboundUsers?[inboundUser];
      if (grant != null) {
        final flow = entry['id'],
            upload = entry['upload'],
            download = entry['download'];
        if (flow is! String || upload is! int || download is! int) {
          result[grant] = RecipientPresence.unavailable;
          continue;
        }
        samples[flow] = (
          grant: grant,
          upload: upload,
          download: download,
          start: DateTime.tryParse(entry['start']?.toString() ?? ''),
        );
      } else if (inboundUsers != null &&
          (inboundUser is! String || inboundUser.isEmpty)) {
        for (final id in inboundUsers.values) {
          if (result[id] == RecipientPresence.offline)
            result[id] = RecipientPresence.unavailable;
        }
      }
    }
    traffic.observe(samples, _now());
    for (final grant in result.keys) {
      if (traffic.online(grant)) result[grant] = RecipientPresence.online;
    }
    return result;
  }

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
