import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:yaml/yaml.dart';
import '../config.dart';
import '../errors.dart';
import '../panel/configuration_codec.dart';
import '../panel/domain.dart';
import '../panel/validation.dart';
import 'contracts.dart';
import 'socket_owner.dart';

class MihomoConfiguration implements ConfigurationCodec {
  MihomoConfiguration({this.supervisor});
  final ProcessSupervisor? supervisor;
  @override
  String get coreId => 'mihomo';
  @override
  ClientEndpoint clientEndpoint(
    StoredConnection c,
    AccessGrant grant,
    String address,
  ) => ClientEndpoint(
    id: c.value.id,
    name: c.value.name,
    server: address,
    port: c.value.port!,
    protocolId: c.value.protocolId,
    settings: Map.of(c.value.settings),
    credentials: {
      'uuid': grant.credentials['uuid']!,
      'publicKey': c.secrets['publicKey']!,
      'shortId': c.secrets['shortId']!,
    },
  );
  @override
  Future<void> preflight(
    PanelData before,
    PanelData after,
    bool running,
  ) async {
    final owned = running
        ? before.listeningConnections.map((c) => c.value.port).toSet()
        : <int?>{};
    for (final c in after.listeningConnections) {
      if (owned.contains(c.value.port) || c.value.port! < 1024) continue;
      try {
        final socket = await ServerSocket.bind(
          c.value.settings['listen']!,
          c.value.port!,
          shared: false,
        );
        await socket.close();
      } on SocketException {
        throw const ApiException('port_unavailable', status: 422);
      }
    }
  }

  @override
  List<ProtocolDefinition> get protocols => const [
    ProtocolDefinition('vless', 'VLESS', [
      ProtocolField(
        'transport',
        defaultValue: 'TCP',
        options: ['TCP'],
        required: true,
      ),
      ProtocolField(
        'security',
        defaultValue: 'REALITY',
        options: ['REALITY'],
        required: true,
      ),
      ProtocolField('listen', defaultValue: '::', required: true),
      ProtocolField(
        'serverName',
        defaultValue: 'www.microsoft.com',
        helpKey: 'help.realityServerName',
        required: true,
      ),
      ProtocolField('handshakePort', defaultValue: '443', required: true),
      ProtocolField(
        'flow',
        defaultValue: 'xtls-rprx-vision',
        options: ['xtls-rprx-vision', 'None'],
        required: true,
      ),
    ]),
  ];
  @override
  Map<String, String> validateSettings(Connection connection) {
    final protocol = protocols
        .where((p) => p.id == connection.protocolId)
        .firstOrNull;
    if (protocol == null)
      throw const ApiException('protocol_unavailable', status: 422);
    final allowed = protocol.fields.map((f) => f.id).toSet();
    if (connection.settings.keys.any((k) => !allowed.contains(k)))
      throw const ApiException('settings_unsupported', status: 422);
    final settings = <String, String>{};
    for (final f in protocol.fields) {
      final value = (connection.settings[f.id] ?? f.defaultValue).trim();
      if ((f.required && value.isEmpty) ||
          value.length > 253 ||
          (f.options.isNotEmpty && !f.options.contains(value))) {
        throw const ApiException('settings_unsupported', status: 422);
      }
      settings[f.id] = value;
    }
    if (InternetAddress.tryParse(settings['listen']!) == null)
      throw const ApiException('listen_invalid', status: 422);
    if (!validAddress(settings['serverName']!) ||
        InternetAddress.tryParse(settings['serverName']!) != null)
      throw const ApiException('sni_invalid', status: 422);
    final destPort = int.tryParse(settings['handshakePort']!);
    if (destPort == null || destPort < 1 || destPort > 65535)
      throw const ApiException('handshake_port_invalid', status: 422);
    return settings;
  }

  @override
  Future<Map<String, String>> connectionSecrets(Connection connection) async {
    final key = await (await X25519().newKeyPair()).extract();
    final random = Random.secure();
    return {
      'privateKey': base64Url.encode(key.bytes).replaceAll('=', ''),
      'publicKey': base64Url.encode(key.publicKey.bytes).replaceAll('=', ''),
      'shortId': List.generate(
        8,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
    };
  }

  @override
  Future<Map<String, String>> grantCredentials(
    StoredConnection connection,
  ) async => {'uuid': newUuid()};
  @override
  Future<void> verifyRunning(PanelData data, ManagedCore core) async {
    if (data.listeningConnections.isEmpty) return;
    final processId = (await supervisor?.inspect(core))?.processId;
    if (processId == null || processId <= 0)
      throw const ApiException('listener_identity_unavailable');
    final uid = await processUid(processId);
    for (final c in data.listeningConnections) {
      final listen = c.value.settings['listen']!;
      final host = listen == '::'
          ? '::1'
          : listen == '0.0.0.0'
          ? '127.0.0.1'
          : listen;
      try {
        final socket = await Socket.connect(
          host,
          c.value.port!,
          timeout: const Duration(seconds: 2),
        );
        try {
          if (!await peerBelongsTo(socket, uid))
            throw const ApiException('listener_not_ready');
        } finally {
          socket.destroy();
        }
      } on SocketException {
        throw const ApiException('listener_not_ready', status: 503);
      }
    }
  }

  @override
  String compile(PanelData data, ManagedCore core, String previous) {
    final loaded = loadYaml(previous);
    if (loaded is! Map)
      throw const ApiException('configuration_invalid', status: 422);
    final base = Map<String, Object?>.from(_plain(loaded) as Map);
    final listeners = base['listeners'];
    if (listeners != null && listeners is! List)
      throw const ApiException('configuration_invalid', status: 422);
    final owned = <Map<String, Object?>>[];
    for (final stored in data.listeningConnections) {
      final c = stored.value;
      if (c.coreId != coreId || c.instanceId != core.id)
        throw const ApiException('core_unavailable', status: 422);
      final s = validateSettings(c);
      owned.add({
        'name': 'sky-ui/${c.id}',
        'type': 'vless',
        'listen': s['listen'],
        'port': c.port,
        'proxy': 'DIRECT',
        'users': [
          for (final g in data.activeGrants(c.id))
            {
              'username': g.id,
              'uuid': g.credentials['uuid'],
              if (s['flow'] != 'None') 'flow': s['flow'],
            },
        ],
        'reality-config': {
          'dest': '${s['serverName']}:${s['handshakePort']}',
          'private-key': stored.secrets['privateKey'],
          'short-id': [stored.secrets['shortId']],
          'server-names': [s['serverName']],
        },
      });
    }
    base['listeners'] = [
      if (listeners is List)
        ...listeners.where(
          (v) =>
              v is! Map ||
              !(v['name']?.toString().startsWith('sky-ui/') ?? false),
        ),
      ...owned,
    ];
    return '${const JsonEncoder.withIndent('  ').convert(base)}\n';
  }
}

Object? _plain(Object? value) {
  if (value is Map)
    return value.map((k, v) => MapEntry(k.toString(), _plain(v)));
  if (value is List) return value.map(_plain).toList();
  return value;
}
