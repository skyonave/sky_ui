import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

String secureToken([int bytes = 32]) => base64Url
    .encode(List<int>.generate(bytes, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');
String newId(String prefix) => '${prefix}_${secureToken(16)}';
String digest(String value) => sha256.convert(utf8.encode(value)).toString();
String newUuid() {
  final random = Random.secure();
  final b = List<int>.generate(16, (_) => random.nextInt(256));
  b[6] = (b[6] & 15) | 0x40;
  b[8] = (b[8] & 63) | 0x80;
  final s = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
}

class StoredConnection {
  const StoredConnection(this.value, this.secrets);
  final Connection value;
  final Map<String, String> secrets;
}

// Explicitly contains client-visible material only, never a server private key.
class ClientEndpoint {
  const ClientEndpoint({
    required this.id,
    required this.name,
    required this.server,
    required this.port,
    required this.protocolId,
    required this.settings,
    required this.credentials,
  });
  final String id;
  final String name;
  final String server;
  final int port;
  final String protocolId;
  final Map<String, String> settings;
  final Map<String, String> credentials;
}

class StoredRecipient {
  const StoredRecipient({
    required this.id,
    required this.name,
    required this.enabled,
    required this.token,
  });
  final String id;
  final String name;
  final bool enabled;
  final String token;
}

class AccessGrant {
  const AccessGrant({
    required this.id,
    required this.recipientId,
    required this.connectionId,
    required this.credentials,
  });
  final String id;
  final String recipientId;
  final String connectionId;
  final Map<String, String> credentials;
}

class PanelData {
  PanelData({
    required this.serverName,
    required this.address,
    List<StoredConnection>? connections,
    List<StoredRecipient>? recipients,
    List<AccessGrant>? grants,
    Map<String, Map<String, String>>? coreSettings,
  }) : connections = connections ?? [],
       recipients = recipients ?? [],
       grants = grants ?? [],
       coreSettings = coreSettings ?? {};
  String serverName;
  String address;
  final List<StoredConnection> connections;
  final List<StoredRecipient> recipients;
  final List<AccessGrant> grants;
  final Map<String, Map<String, String>> coreSettings;
  PanelData copy() => PanelData(
    serverName: serverName,
    address: address,
    connections: [...connections],
    recipients: [...recipients],
    grants: [...grants],
    coreSettings: {
      for (final e in coreSettings.entries) e.key: {...e.value},
    },
  );

  /// A codec sees only its own instance; grants and recipients keep their identity.
  PanelData forInstance(String instanceId) {
    final owned = connections
        .where((c) => c.value.instanceId == instanceId)
        .toList();
    final ids = owned.map((c) => c.value.id).toSet();
    return PanelData(
      serverName: serverName,
      address: address,
      connections: owned,
      recipients: [...recipients],
      grants: grants.where((g) => ids.contains(g.connectionId)).toList(),
      coreSettings: {
        if (coreSettings.containsKey(instanceId))
          instanceId: {...coreSettings[instanceId]!},
      },
    );
  }

  Recipient publicRecipient(StoredRecipient value) => Recipient(
    id: value.id,
    name: value.name,
    enabled: value.enabled,
    connectionPorts: {
      for (final grant in grants.where(
        (g) => g.recipientId == value.id && g.credentials['port'] != null,
      ))
        grant.connectionId: int.parse(grant.credentials['port']!),
    },
    connectionIds: grants
        .where((g) => g.recipientId == value.id)
        .map((g) => g.connectionId)
        .toList(),
  );
  List<AccessGrant> activeGrants(String connectionId) => grants
      .where(
        (g) =>
            g.connectionId == connectionId &&
            recipients.any((u) => u.id == g.recipientId && u.enabled),
      )
      .toList();
  List<StoredConnection> get listeningConnections => connections
      .where(
        (c) =>
            c.value.enabled &&
            (!c.value.shareable || activeGrants(c.value.id).isNotEmpty),
      )
      .toList();
}
