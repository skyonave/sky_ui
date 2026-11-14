import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../application/access/records.dart';
import '../../application/contracts/configuration_codec.dart';
import '../../application/contracts/connection_diagnostics.dart';
import '../../shared/api_exception.dart';
import '../managed_core.dart';

class AmneziaConfiguration
    implements ConfigurationCodec, GrantAllocator, ConnectionDiagnosticsCodec {
  @override
  ConnectionDiagnosticPlan diagnosticPlan(
    PanelData data,
    StoredConnection connection,
  ) => ConnectionDiagnosticPlan(
    listeners: [
      if (connection.value.enabled)
        DiagnosticListener(
          host: '0.0.0.0',
          port: connection.value.port!,
          udp: true,
          interfaceName: interfaceName(connection.value.id),
        ),
    ],
    tlsSkipCode: 'awg_client_required',
  );
  @override
  String get coreId => 'amneziawg';
  static const integerOptions = <String, (int, int, int)>{
    'Jc': (4, 0, 128),
    'Jmin': (40, 0, 1280),
    'Jmax': (70, 0, 1280),
    'S1': (64, 12, 1024),
    'S2': (64, 12, 1024),
    'S3': (32, 12, 1024),
    'S4': (32, 12, 1024),
    'H1': (1, 1, 4294967295),
    'H2': (2, 1, 4294967295),
    'H3': (3, 1, 4294967295),
    'H4': (4, 1, 4294967295),
    'RekeyAfterTime': (120, 10, 86400),
    'RekeyTimeout': (5, 1, 120),
    'RejectAfterTime': (180, 20, 172800),
    'KeepaliveTimeout': (10, 1, 120),
    'MaxHandshakeAttempts': (18, 1, 128),
  };
  @override
  List<ProtocolDefinition> get protocols => [
    ProtocolDefinition('amneziawg', 'AmneziaWG 3.1', [
      const ProtocolField(
        'serverAddress',
        defaultValue: '10.66.0.1/24',
        required: true,
      ),
      const ProtocolField(
        'dns',
        kind: 'lines',
        defaultValue: '1.1.1.1\n9.9.9.9',
        required: true,
      ),
      const ProtocolField(
        'mtu',
        kind: 'integer',
        defaultValue: '1280',
        minimum: 1280,
        maximum: 1420,
      ),
      const ProtocolField(
        'keepalive',
        kind: 'integer',
        defaultValue: '25',
        minimum: 0,
        maximum: 65535,
      ),
      for (final entry in integerOptions.entries)
        ProtocolField(
          'awg.${entry.key}',
          kind: 'integer',
          advanced: true,
          defaultValue: '${entry.value.$1}',
          minimum: entry.value.$2,
          maximum: entry.value.$3,
          labelKey: 'awg.${entry.key}',
          helpKey: 'awg.${entry.key}.help',
          generator: entry.key.startsWith('H') && entry.key.length == 2
              ? 'awg-header'
              : ['S1', 'S2'].contains(entry.key)
              ? 'awg-padding'
              : ['S3', 'S4'].contains(entry.key)
              ? 'awg-small-padding'
              : entry.key == 'Jc'
              ? 'awg-junk-count'
              : ['Jmin', 'Jmax'].contains(entry.key)
              ? 'awg-junk-size'
              : null,
        ),
      const ProtocolField(
        'awg.ContentPaddingAddition',
        defaultValue: '0-32',
        pattern: r'^\d{1,4}(?:-\d{1,4})?$',
        advanced: true,
        labelKey: 'awg.ContentPaddingAddition',
        helpKey: 'awg.ContentPaddingAddition.help',
      ),
      const ProtocolField(
        'awg.RandomTrailers',
        kind: 'boolean',
        defaultValue: 'true',
        advanced: true,
        labelKey: 'awg.RandomTrailers',
        helpKey: 'awg.RandomTrailers.help',
      ),
      const ProtocolField(
        'awg.DisableCookies',
        kind: 'boolean',
        defaultValue: 'false',
        advanced: true,
        labelKey: 'awg.DisableCookies',
        helpKey: 'awg.DisableCookies.help',
      ),
      for (var i = 1; i <= 5; i++)
        ProtocolField(
          'awg.I$i',
          maxLength: 2048,
          advanced: true,
          labelKey: 'awg.I$i',
          helpKey: 'awg.I.help',
        ),
    ]),
  ];
  static ({int address, int prefix, int network, int last}) subnet(
    String text,
  ) {
    final parts = text.split('/'), ip = InternetAddress.tryParse(parts.first);
    final prefix = parts.length == 2 ? int.tryParse(parts.last) : null;
    if (ip == null ||
        ip.type != InternetAddressType.IPv4 ||
        prefix == null ||
        prefix < 24 ||
        prefix > 30)
      throw const ApiException(
        'settings_unsupported',
        status: 422,
        fields: {'serverAddress': 'format_invalid'},
      );
    final b = ip.rawAddress,
        value = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
    if (!(b[0] == 10 ||
        b[0] == 172 && b[1] >= 16 && b[1] <= 31 ||
        b[0] == 192 && b[1] == 168))
      throw const ApiException(
        'settings_unsupported',
        status: 422,
        fields: {'serverAddress': 'format_invalid'},
      );
    final network = value & (0xffffffff << (32 - prefix)),
        last = network + (1 << (32 - prefix)) - 1;
    if (value == network || value == last)
      throw const ApiException(
        'settings_unsupported',
        status: 422,
        fields: {'serverAddress': 'format_invalid'},
      );
    return (address: value, prefix: prefix, network: network, last: last);
  }

  static String ip(int value) =>
      '${(value >> 24) & 255}.${(value >> 16) & 255}.${(value >> 8) & 255}.${value & 255}';
  static String interfaceName(String id) =>
      'skyawg${digest(id).substring(0, 8)}';
  @override
  Map<String, String> validateSettings(Connection connection) {
    final d = protocols.single;
    if (connection.protocolId != d.id ||
        connection.settings.keys.any((id) => !d.fields.any((f) => f.id == id)))
      throw const ApiException('settings_unsupported', status: 422);
    final values = d.defaults(connection.settings),
        errors = d.validateFields(d.defaults(connection.settings));
    subnet(values['serverAddress'] ?? '');
    if ((values['dns'] ?? '')
        .split('\n')
        .any(
          (v) =>
              InternetAddress.tryParse(v.trim())?.type !=
              InternetAddressType.IPv4,
        ))
      errors['dns'] = 'format_invalid';
    if ((int.tryParse(values['awg.Jmin'] ?? '') ?? 0) >
        (int.tryParse(values['awg.Jmax'] ?? '') ?? 0))
      errors['awg.Jmax'] = 'range_invalid';
    if ((int.tryParse(values['awg.RejectAfterTime'] ?? '') ?? 0) <=
        (int.tryParse(values['awg.RekeyAfterTime'] ?? '') ?? 0))
      errors['awg.RejectAfterTime'] = 'range_invalid';
    for (var i = 1; i <= 5; i++) {
      if (!validSignature(values['awg.I$i'] ?? ''))
        errors['awg.I$i'] = 'format_invalid';
    }
    final padding = (values['awg.ContentPaddingAddition'] ?? '')
        .split('-')
        .map(int.tryParse)
        .toList();
    if (padding.any((n) => n == null || n > 4096) ||
        padding.length > 1 && padding.first! > padding.last!)
      errors['awg.ContentPaddingAddition'] = 'range_invalid';
    if (errors.isNotEmpty)
      throw ApiException('settings_unsupported', status: 422, fields: errors);
    return values;
  }

  static bool validSignature(String value) {
    if (value.isEmpty) return true;
    final tag = RegExp(r'<(?:b 0x([a-fA-F0-9]+)|(r|rd|rc) ([0-9]{1,4})|(t))>');
    var offset = 0, size = 0;
    for (final match in tag.allMatches(value)) {
      if (match.start != offset) return false;
      offset = match.end;
      if (match[1] != null) {
        if (match[1]!.length.isOdd) return false;
        size += match[1]!.length ~/ 2;
      } else {
        size += match[3] != null ? int.parse(match[3]!) : 4;
      }
      if (size > 1280) return false;
    }
    return offset == value.length;
  }

  Future<Map<String, String>> _keyPair() async {
    final key = await (await X25519().newKeyPair()).extract();
    return {
      'privateKey': base64.encode(key.bytes),
      'publicKey': base64.encode(key.publicKey.bytes),
    };
  }

  @override
  Future<Map<String, String>> connectionSecrets(
    Connection connection, {
    Map<String, String> previous = const {},
  }) async => {
    ...previous,
    if (!previous.containsKey('privateKey')) ...await _keyPair(),
    'headerProtectionKey':
        previous['headerProtectionKey'] ??
        secureToken().replaceAll('-', '+').replaceAll('_', '/') + '=',
  };
  @override
  Future<Map<String, String>> grantCredentials(
    StoredConnection connection, {
    Map<String, String> previous = const {},
  }) async => {
    ...previous,
    if (!previous.containsKey('privateKey')) ...await _keyPair(),
    'presharedKey':
        previous['presharedKey'] ??
        base64.encode(base64Url.decode(secureToken() + '=')),
  };

  @override
  Map<String, String> allocateGrant(
    PanelData data,
    StoredConnection connection,
    Map<String, String> credentials,
  ) {
    final net = subnet(connection.value.settings['serverAddress']!);
    final used = {for (final g in data.grants) g.credentials['address']};
    for (var i = net.network + 1; i < net.last; i++) {
      if (i != net.address && !used.contains('${ip(i)}/32'))
        return {...credentials, 'address': '${ip(i)}/32'};
    }
    throw const ApiException('peer_address_unavailable', status: 422);
  }

  @override
  String compile(
    PanelData data,
    ManagedCore core,
    String previous, {
    bool validationOnly = false,
  }) {
    final networks = <({int start, int end})>[];
    final interfaces = <Map<String, Object?>>[];
    for (final c in data.connections.where((c) => c.value.enabled)) {
      final s = c.value.settings, net = subnet(s['serverAddress']!);
      if (networks.any((n) => net.network <= n.end && n.start <= net.last))
        throw const ApiException('network_in_use', status: 422);
      networks.add((start: net.network, end: net.last));
      for (final grant in data.grants.where(
        (g) => g.connectionId == c.value.id,
      )) {
        final address = InternetAddress.tryParse(
          (grant.credentials['address'] ?? '').split('/').first,
        );
        if (address == null || address.type != InternetAddressType.IPv4)
          throw const ApiException('peer_address_invalid', status: 422);
        final n = address.rawAddress.fold<int>(0, (n, byte) => (n << 8) | byte);
        if (n <= net.network || n >= net.last || n == net.address)
          throw const ApiException('peer_address_invalid', status: 422);
      }
      interfaces.add({
        'name': interfaceName(c.value.id),
        'address': s['serverAddress'],
        'mtu': int.parse(s['mtu']!),
        'port': c.value.port,
        'privateKey': c.secrets['privateKey'],
        'headerProtectionKey': c.secrets['headerProtectionKey'],
        if (c.value.routing[Connection.localNode] case final policy?)
          'routing': policy.toJson(),
        'options': {
          for (final e in s.entries.where(
            (e) => e.key.startsWith('awg.') && e.value.isNotEmpty,
          ))
            e.key.substring(4): e.value,
        },
        'peers': [
          for (final g in data.activeGrants(c.value.id))
            {
              'publicKey': g.credentials['publicKey'],
              'presharedKey': g.credentials['presharedKey'],
              'address': g.credentials['address'],
            },
        ],
      });
    }
    return '${jsonEncode({'version': '3.1', 'interfaces': interfaces})}\n';
  }

  @override
  Future<void> preflight(
    PanelData before,
    PanelData after,
    bool running,
  ) async {
    final previous = running
        ? before.connections
              .where((c) => c.value.enabled)
              .map((c) => c.value.port)
              .toSet()
        : <int?>{};
    for (final c in after.connections.where(
      (c) => c.value.enabled && !previous.contains(c.value.port),
    )) {
      RawDatagramSocket? socket;
      try {
        socket = await RawDatagramSocket.bind(
          '0.0.0.0',
          c.value.port!,
          reuseAddress: false,
          reusePort: false,
        );
      } on SocketException {
        throw const ApiException('port_in_use', status: 422);
      } finally {
        socket?.close();
      }
    }
  }

  @override
  Future<void> verifyRunning(PanelData data, ManagedCore core) async {
    if (!Platform.isLinux) return;
    for (final c in data.connections.where((c) => c.value.enabled)) {
      if (!await Directory(
        '/sys/class/net/${interfaceName(c.value.id)}',
      ).exists())
        throw const ApiException('listener_not_ready');
    }
  }

  @override
  ClientEndpoint clientEndpoint(
    StoredConnection connection,
    AccessGrant grant,
    String address,
  ) => ClientEndpoint(
    id: grant.id,
    name: connection.value.name,
    server: address,
    port: connection.value.port!,
    protocolId: 'amneziawg',
    settings: {
      ...connection.value.settings,
      'security': 'Built-in',
      'transport': 'UDP',
    },
    credentials: {
      for (final key in ['privateKey', 'publicKey', 'presharedKey', 'address'])
        key: grant.credentials[key]!,
      'serverPublicKey': connection.secrets['publicKey']!,
      'headerProtectionKey': connection.secrets['headerProtectionKey']!,
    },
  );
}
