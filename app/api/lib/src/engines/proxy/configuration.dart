import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../application/access/records.dart';
import '../../application/access/validation.dart';
import '../../application/contracts/configuration_codec.dart';
import '../../application/core_settings/form.dart';
import '../../infrastructure/network/socket_owner.dart';
import '../../shared/api_exception.dart';
import '../contracts.dart';
import '../managed_core.dart';
import '../sing_box/settings.dart';
import '../xray/settings.dart';
import 'inbound_builder.dart';
import 'schema.dart';

/// Shared protocol semantics for JSON proxy engines; native documents stay distinct.
class ProxyConfiguration implements ConfigurationCodec, CoreSettingsCodec {
  @override
  List<ProtocolField> get coreSettingsFields =>
      coreId == 'xray' ? XraySettings.fields : SingBoxSettings.fields;
  @override
  Map<String, String> readCoreSettings(
    String native,
    Map<String, String>? stored,
  ) => coreId == 'xray'
      ? XraySettings.read(native, stored)
      : SingBoxSettings.read(native, stored);
  @override
  Map<String, String> prepareCoreSettings(
    String native,
    Map<String, String>? stored,
    Map<String, String> input,
  ) => coreId == 'xray'
      ? XraySettings.prepare(native, stored, input)
      : SingBoxSettings.prepare(native, stored, input);
  ProxyConfiguration(
    this.coreId, {
    required this.supervisor,
    required this.core,
    this.certificatesDirectory = '/var/lib/sky-ui-certificates',
  });
  @override
  final String coreId;
  final ProcessSupervisor supervisor;
  final ManagedCore core;
  final String certificatesDirectory;
  Map<String, dynamic> get certificates {
    try {
      final values =
          jsonDecode(
                File('$certificatesDirectory/index.json').readAsStringSync(),
              )
              as Map;
      return {
        for (final e in values.entries)
          if (e.value is Map &&
              DateTime.tryParse(e.value['expiresAt'] as String? ?? '')?.isAfter(
                    DateTime.now().toUtc().add(const Duration(minutes: 1)),
                  ) ==
                  true)
            e.key as String: e.value,
      };
    } on Object {
      return {};
    }
  }

  @override
  List<ProtocolDefinition> get protocols => [
    for (final id
        in coreId == 'xray'
            ? ['vless', 'shadowsocks']
            : ['vless', 'shadowsocks', 'hysteria2', 'tuic', 'naive'])
      _definition(id),
  ];
  ProtocolDefinition _definition(String id) =>
      proxyProtocolDefinition(coreId, id, certificates);

  @override
  Map<String, String> validateSettings(Connection connection) {
    final d = protocols.where((d) => d.id == connection.protocolId).firstOrNull;
    if (d == null)
      throw const ApiException('protocol_unavailable', status: 422);
    if (connection.settings.keys.any((id) => !d.fields.any((f) => f.id == id)))
      throw const ApiException('settings_unsupported', status: 422);
    final values = d.defaults(connection.settings);
    for (final entry in connection.settings.entries) {
      final field = d.fields.firstWhere((f) => f.id == entry.key);
      if (field.options.isNotEmpty &&
          !field.allowedOptions(values).contains(entry.value)) {
        throw ApiException(
          'settings_unsupported',
          status: 422,
          fields: {entry.key: 'choice_invalid'},
        );
      }
    }
    if (values['security'] == 'TLS' && values['certificateSource'] == 'panel') {
      values['serverName'] =
          certificates[values['certificateId']]?['host'] as String? ??
          values['serverName'] ??
          '';
    }
    final errors = d.validateFields(values);
    if (values['hysteriaMasquerade']?.isNotEmpty == true) {
      final url = Uri.tryParse(values['hysteriaMasquerade']!);
      if (url == null ||
          url.scheme != 'https' ||
          !validAddress(url.host) ||
          url.userInfo.isNotEmpty ||
          url.hasFragment)
        errors['hysteriaMasquerade'] = 'format_invalid';
    }
    if (values['security'] == 'TLS' &&
        double.parse(values['tlsMinVersion']!) >
            double.parse(values['tlsMaxVersion']!)) {
      errors['tlsMaxVersion'] = 'range_invalid';
    }
    final alpn = (values['clientAlpn'] ?? '')
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final allowedAlpn = switch (values['transport']) {
      'WebSocket' => {'http/1.1'},
      'gRPC' => {'h2'},
      _ => {'h2', 'http/1.1'},
    };
    if (alpn.any((value) => !allowedAlpn.contains(value)))
      errors['clientAlpn'] = 'choice_invalid';
    if (values.containsKey('clientAlpn'))
      values['clientAlpn'] = alpn.toSet().join('\n');
    if (values['websocketHost']?.isNotEmpty == true) {
      final host = Uri.tryParse('http://${values['websocketHost']}');
      if (host == null ||
          !validAddress(host.host) ||
          host.userInfo.isNotEmpty ||
          host.path.isNotEmpty ||
          host.hasQuery ||
          host.hasFragment ||
          host.hasPort && (host.port < 1 || host.port > 65535))
        errors['websocketHost'] = 'format_invalid';
    }
    if (InternetAddress.tryParse(values['listen'] ?? '') == null)
      errors['listen'] = 'format_invalid';
    if (values['serverName']?.isNotEmpty == true &&
        !validAddress(values['serverName']!))
      errors['serverName'] = 'format_invalid';
    if (values['security'] == 'REALITY') {
      final target = values['realityTarget'] ?? '';
      final parsed = Uri.tryParse('tcp://$target');
      if (parsed == null ||
          !validAddress(parsed.host) ||
          parsed.userInfo.isNotEmpty ||
          parsed.path.isNotEmpty ||
          parsed.hasQuery ||
          parsed.hasFragment ||
          !parsed.hasPort ||
          parsed.port < 1 ||
          parsed.port > 65535)
        errors['realityTarget'] = 'format_invalid';
    }
    if (values['security'] == 'TLS') {
      if (values['certificateSource'] == 'panel' &&
          !certificates.containsKey(values['certificateId']))
        errors['certificateId'] = 'choice_invalid';
      if (values['certificateSource'] == 'custom') {
        try {
          SecurityContext(withTrustedRoots: false)
            ..useCertificateChainBytes(
              utf8.encode(values['tlsCertificate'] ?? ''),
            )
            ..usePrivateKeyBytes(utf8.encode(values['tlsPrivateKey'] ?? ''));
        } on Object {
          errors['tlsCertificate'] = 'certificate_invalid';
        }
      }
    }
    for (final id in ['websocketPath', 'xhttpPath']) {
      if (values[id]?.isNotEmpty == true &&
          (!values[id]!.startsWith('/') ||
              values[id]!.contains(RegExp(r'[\r\n]'))))
        errors[id] = 'format_invalid';
    }
    if (errors.isNotEmpty)
      throw ApiException('settings_unsupported', status: 422, fields: errors);
    return {
      for (final f in d.activeFields(values))
        f.id: values[f.id] ?? f.initialValue(values),
    };
  }

  Map<String, String> _settings(StoredConnection connection) => {
    ...connection.value.settings,
    for (final f in _definition(
      connection.value.protocolId,
    ).fields.where((f) => f.secret))
      if (connection.secrets['field:${f.id}'] != null)
        f.id: connection.secrets['field:${f.id}']!,
  };
  @override
  Future<Map<String, String>> connectionSecrets(
    Connection connection, {
    Map<String, String> previous = const {},
  }) async {
    final values = {...previous};
    if (connection.protocolId == 'hysteria2' &&
        connection.settings['obfs'] == 'salamander' &&
        (values['field:obfsPassword'] ?? '').isEmpty) {
      values['field:obfsPassword'] =
          connection.settings['obfsPassword']?.isNotEmpty == true
          ? connection.settings['obfsPassword']!
          : secureToken();
    }
    if (connection.settings['security'] == 'REALITY' &&
        values['privateKey'] == null) {
      final key = await (await X25519().newKeyPair()).extract();
      values.addAll({
        'privateKey': base64Url.encode(key.bytes).replaceAll('=', ''),
        'publicKey': base64Url.encode(key.publicKey.bytes).replaceAll('=', ''),
        'shortId': List.generate(
          8,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
      });
    }
    return values;
  }

  @override
  Future<Map<String, String>> grantCredentials(
    StoredConnection connection, {
    Map<String, String> previous = const {},
  }) async => {
    ...previous,
    'uuid': previous['uuid'] ?? newUuid(),
    'username': previous['username'] ?? secureToken(12),
    'password': previous['password'] ?? secureToken(),
  };

  List<
    ({
      StoredConnection connection,
      List<AccessGrant> grants,
      int port,
      String tag,
    })
  >
  _listeners(PanelData data, bool validationOnly) {
    return [
      for (final c in data.connections.where((c) => c.value.enabled))
        if (data.activeGrants(c.value.id).isNotEmpty || validationOnly)
          for (final grants
              in _definition(c.value.protocolId).isolatedBindings
                  ? [
                      for (final g in data.activeGrants(c.value.id)) [g],
                      if (validationOnly &&
                          data.activeGrants(c.value.id).isEmpty)
                        [_validationGrant(c)],
                    ]
                  : [
                      data.activeGrants(c.value.id).isEmpty
                          ? [_validationGrant(c)]
                          : data.activeGrants(c.value.id),
                    ])
            (
              connection: c,
              grants: grants,
              port:
                  int.tryParse(grants.first.credentials['port'] ?? '') ??
                  c.value.port!,
              tag:
                  'sky-${c.value.id}${_definition(c.value.protocolId).isolatedBindings ? '-${grants.first.id}' : ''}',
            ),
    ];
  }

  AccessGrant _validationGrant(StoredConnection c) => AccessGrant(
    id: 'validation',
    recipientId: '',
    connectionId: c.value.id,
    credentials: {
      'uuid': 'fdd8be42-a0f8-4370-a01b-5735ca178849',
      'username': 'validation',
      'password': 'validation-configuration-only',
    },
  );
  @override
  String compile(
    PanelData data,
    ManagedCore core,
    String previous, {
    bool validationOnly = false,
  }) {
    final builder = ProxyInboundBuilder(
      coreId: coreId,
      certificatesDirectory: certificatesDirectory,
      certificates: certificates,
      readSettings: _settings,
    );
    final inbounds = [
      for (final l in _listeners(data, validationOnly))
        builder.build(l.connection, l.grants, l.port, l.tag),
    ];
    final defaults = coreId == 'xray'
        ? {
            'log': {'loglevel': 'warning'},
            'inbounds': inbounds,
            'outbounds': [
              {'protocol': 'freedom', 'tag': 'direct'},
            ],
          }
        : {
            'log': {'level': 'info', 'timestamp': true},
            'inbounds': inbounds,
            'outbounds': [
              {'type': 'direct', 'tag': 'direct'},
            ],
          };
    final base = previous.trim().isEmpty
        ? Map<String, dynamic>.from(defaults)
        : CoreSettingsForm.document(previous);
    final existing = base['inbounds'];
    if (existing != null && existing is! List)
      throw const ApiException('configuration_invalid', status: 422);
    base['inbounds'] = [
      if (existing is List)
        ...existing.where(
          (i) =>
              i is! Map || !(i['tag']?.toString().startsWith('sky-') ?? false),
        ),
      ...inbounds,
    ];
    base['outbounds'] ??= defaults['outbounds'];
    if (base['outbounds'] is! List || (base['outbounds'] as List).isEmpty)
      throw const ApiException('configuration_invalid', status: 422);
    final tags = inbounds.map((i) => i['tag'] as String).toList();
    if (coreId == 'xray') {
      XraySettings.apply(base, tags, data.coreSettings[core.id]);
    } else {
      SingBoxSettings.apply(base, tags, data.coreSettings[core.id]);
    }
    return '${const JsonEncoder.withIndent('  ').convert(base)}\n';
  }

  @override
  Future<void> preflight(
    PanelData before,
    PanelData after,
    bool running,
  ) async {
    final previous = running
        ? _listeners(before, false).map((l) => l.port).toSet()
        : <int>{};
    for (final l in _listeners(after, false)) {
      if (previous.contains(l.port)) continue;
      ServerSocket? tcp;
      RawDatagramSocket? udp;
      try {
        final quic =
            {'tuic', 'hysteria2'}.contains(l.connection.value.protocolId) ||
            _settings(l.connection)['transport'] == 'HTTP/3';
        if (!quic)
          tcp = await ServerSocket.bind(
            _settings(l.connection)['listen'] ?? '::',
            l.port,
            shared: false,
          );
        if (quic || l.connection.value.protocolId == 'shadowsocks')
          udp = await RawDatagramSocket.bind(
            _settings(l.connection)['listen'] ?? '::',
            l.port,
            reuseAddress: false,
            reusePort: false,
          );
      } on SocketException {
        throw const ApiException('port_in_use', status: 422);
      } finally {
        await tcp?.close();
        udp?.close();
      }
    }
  }

  @override
  Future<void> verifyRunning(PanelData data, ManagedCore core) async {
    final process = await supervisor.inspect(core);
    if (!Platform.isLinux) return;
    if (process.processId == null || process.processId! <= 0)
      throw const ApiException('listener_not_ready');
    final uid = await processUid(process.processId!);
    for (final l in _listeners(data, false)) {
      final quic =
          {'tuic', 'hysteria2'}.contains(l.connection.value.protocolId) ||
          _settings(l.connection)['transport'] == 'HTTP/3';
      var ready = false;
      for (var attempt = 0; attempt < 15; attempt++) {
        if (await boundSocketBelongsTo(
              _settings(l.connection)['listen'] ?? '::',
              l.port,
              uid,
              udp: quic,
            ) &&
            (l.connection.value.protocolId != 'shadowsocks' ||
                await boundSocketBelongsTo(
                  _settings(l.connection)['listen'] ?? '::',
                  l.port,
                  uid,
                  udp: true,
                ))) {
          ready = true;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (!ready) throw const ApiException('listener_not_ready');
    }
  }

  @override
  ClientEndpoint clientEndpoint(
    StoredConnection connection,
    AccessGrant grant,
    String address,
  ) {
    final s = _settings(connection);
    return ClientEndpoint(
      id: grant.id,
      name: connection.value.name,
      server: address,
      port:
          int.tryParse(grant.credentials['port'] ?? '') ??
          connection.value.port!,
      protocolId: connection.value.protocolId,
      settings: {
        for (final key in [
          'transport',
          'security',
          'serverName',
          'flow',
          'clientFingerprint',
          'clientAlpn',
          'websocketPath',
          'websocketHost',
          'grpcServiceName',
          'cipher',
          'congestionController',
          'obfs',
          'obfsPassword',
        ])
          if (s[key] != null) key: s[key]!,
        if (s['transport'] == 'XHTTP')
          'xhttpOptions': jsonEncode({
            'path': s['xhttpPath'],
            'mode': s['xhttpMode'],
            if (s['xhttpHost']?.isNotEmpty == true) 'host': s['xhttpHost'],
          }),
        if (coreId == 'xray' && s['security'] == 'REALITY')
          'realityMlkem': 'true',
        if (connection.value.protocolId == 'hysteria2')
          'protocolOptions': jsonEncode({
            if (s['obfs']?.isNotEmpty == true) ...{
              'obfs': s['obfs'],
              'obfs-password': s['obfsPassword'],
            },
            'up': '${s['upMbps']} Mbps',
            'down': '${s['downMbps']} Mbps',
          }),
        if (connection.value.protocolId == 'tuic')
          'protocolOptions': jsonEncode({
            'congestion-controller': s['congestionController'],
          }),
      },
      credentials: {
        for (final key in ['uuid', 'username', 'password'])
          if (grant.credentials[key] != null) key: grant.credentials[key]!,
        if (s['security'] == 'REALITY') ...{
          'publicKey': connection.secrets['publicKey']!,
          'shortId': connection.secrets['shortId']!,
        },
      },
    );
  }
}
