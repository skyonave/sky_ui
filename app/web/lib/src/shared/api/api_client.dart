import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:web/web.dart' as web;

class ApiClientException implements Exception {
  const ApiClientException(this.code, {this.fields = const {}});
  final String code;
  final Map<String, String> fields;
}

class ApiClient {
  Future<void> updateServerEngine(String id, String core) async {
    await _request(
      '/api/v1/servers/$id/engines/$core/update',
      post: true,
      timeout: const Duration(minutes: 15),
      payload: {},
    );
  }

  Future<void> removeServerEngine(String id, String core) async {
    await _request('/api/v1/servers/$id/engines/$core', method: 'DELETE');
  }

  Future<void> updateServerDetails(
    String id,
    String name,
    String endpoint,
  ) async {
    await _request(
      '/api/v1/servers/$id',
      method: 'PUT',
      payload: {'name': name, 'endpoint': endpoint},
    );
  }

  Future<List<Map<String, dynamic>>> serverEngines(
    String id, {
    bool updates = false,
  }) async => [
    for (final value
        in (await _request(
              '/api/v1/servers/$id/engines${updates ? '?updates=true' : ''}',
            ))['data']
            as List)
      Map<String, dynamic>.from(value as Map),
  ];

  Future<void> installServerEngine(String id, String core) async {
    await _request(
      '/api/v1/servers/$id/engines/$core/install',
      post: true,
      timeout: const Duration(minutes: 15),
      payload: {},
    );
  }

  Future<void> updateServerEndpoint(String id, String endpoint) async {
    await _request(
      '/api/v1/servers/$id/endpoint',
      method: 'PUT',
      payload: {'endpoint': endpoint},
    );
  }

  Future<PanelSnapshot> saveNamedRoute(int revision, NamedRoute route) =>
      _mutate(
        route.id.isEmpty ? '/api/v1/routes' : '/api/v1/routes/${route.id}',
        route.id.isEmpty ? 'POST' : 'PUT',
        {'revision': revision, 'route': route.toJson()},
      );
  Future<PanelSnapshot> deleteNamedRoute(int revision, String id) =>
      _mutate('/api/v1/routes/$id', 'DELETE', {'revision': revision});
  Future<({bool enabled, List<ServerNode> nodes})> servers() async {
    final response = await _request('/api/v1/servers');
    return (
      enabled: response['enabled'] == true,
      nodes: [
        for (final node in response['data'] as List)
          ServerNode.fromJson(Map<String, dynamic>.from(node as Map)),
      ],
    );
  }

  Future<ServerNode> addServer({
    required String name,
    required String host,
    required int port,
    required String hostKey,
    required String endpoint,
    required String relayAddress,
  }) async => ServerNode.fromJson(
    Map<String, dynamic>.from(
      (await _request(
            '/api/v1/servers',
            post: true,
            payload: {
              'name': name,
              'host': host,
              'port': port,
              'hostKey': hostKey,
              'endpoint': endpoint,
              'relayAddress': relayAddress,
            },
          ))['data']
          as Map,
    ),
  );

  Future<String> serverOperation(
    String id,
    ServerOperation operation, {
    String engine = 'mihomo',
  }) async =>
      (await _request(
            '/api/v1/servers/$id/operation',
            post: true,
            payload: {'operation': operation.name, 'engine': engine},
          ))['data']
          as String;

  Future<void> removeServer(String id) async {
    await _request('/api/v1/servers/$id', method: 'DELETE');
  }

  Future<void> bootstrapServer(
    String id,
    String user,
    String key,
    String password,
  ) async {
    await _request(
      '/api/v1/servers/$id/bootstrap',
      post: true,
      timeout: const Duration(minutes: 4),
      payload: {'user': user, 'key': key, 'password': password},
    );
  }

  Future<PanelHttpsStatus> panelHttps() async => PanelHttpsStatus.fromJson(
    Map<String, dynamic>.from(
      (await _request('/api/v1/panel/https'))['data'] as Map,
    ),
  );

  Future<MaintenanceJob> changePanelHttps(
    String domain,
    String expectedDomain,
  ) async => MaintenanceJob.fromJson(
    Map<String, dynamic>.from(
      (await _request(
            '/api/v1/panel/https',
            method: 'POST',
            payload: {
              'confirmed': true,
              'domain': domain,
              'expectedDomain': expectedDomain,
            },
          ))['data']
          as Map,
    ),
  );

  Future<({int revision, Map<String, RecipientPresence> recipients})>
  recipientPresence() async {
    final data =
        (await _request(
              '/api/v1/recipients/presence',
              timeout: const Duration(seconds: 4),
            ))['data']
            as Map;
    return (
      revision: data['revision'] as int,
      recipients: {
        for (final entry in (data['recipients'] as Map).entries)
          entry.key as String: RecipientPresence.values.firstWhere(
            (value) => value.name == entry.value,
            orElse: () => RecipientPresence.unavailable,
          ),
      },
    );
  }

  Future<ConnectionDiagnostics> startDiagnostics(
    String connection,
    int revision,
  ) async => ConnectionDiagnostics.fromJson(
    Map<String, dynamic>.from(
      (await _request(
            '/api/v1/connections/$connection/diagnostics',
            timeout: const Duration(seconds: 8),
            method: 'POST',
            payload: {'revision': revision},
          ))['data']
          as Map,
    ),
  );
  Future<ConnectionDiagnostics> diagnostics(
    String connection,
    String id,
  ) async => ConnectionDiagnostics.fromJson(
    Map<String, dynamic>.from(
      (await _request(
            '/api/v1/connections/$connection/diagnostics/$id',
            timeout: const Duration(seconds: 8),
          ))['data']
          as Map,
    ),
  );
  Future<void> cancelDiagnostics(String connection, String id) async {
    await _request(
      '/api/v1/connections/$connection/diagnostics/$id',
      method: 'DELETE',
      timeout: const Duration(seconds: 8),
    );
  }

  String? csrfToken;
  void Function()? onUnauthorized;
  Future<OwnerState> owner() async => OwnerState.fromJson(
    Map<String, dynamic>.from(
      (await _request('/api/v1/auth/session'))['data'] as Map,
    ),
  );
  Future<OwnerState> login(String username, String password) async =>
      OwnerState.fromJson(
        Map<String, dynamic>.from(
          (await _request(
                '/api/v1/auth/login',
                post: true,
                payload: {'username': username, 'password': password},
              ))['data']
              as Map,
        ),
      );
  Future<void> logout() async {
    await _request('/api/v1/auth/logout', post: true);
  }

  Future<OwnerState> changeOwner(Map<String, Object?> values) async =>
      OwnerState.fromJson(
        Map<String, dynamic>.from(
          (await _request(
                '/api/v1/auth/owner',
                method: 'PUT',
                payload: values,
              ))['data']
              as Map,
        ),
      );
  Future<List<OwnerSession>> ownerSessions() async =>
      ((await _request('/api/v1/auth/sessions'))['data'] as List)
          .map(
            (v) => OwnerSession.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList();
  Future<void> revokeSession(String id) async {
    await _request('/api/v1/auth/sessions/$id', method: 'DELETE', payload: {});
  }

  Future<void> revokeOtherSessions() async {
    await _request(
      '/api/v1/auth/sessions/revoke-others',
      post: true,
      payload: {'confirmed': true},
    );
  }

  Future<SystemSnapshot> system() async => SystemSnapshot.fromJson(
    Map<String, dynamic>.from(
      (await _request('/api/v1/system'))['data'] as Map,
    ),
  );
  Future<CoreUpdateInfo> updates(String core) async => CoreUpdateInfo.fromJson(
    Map<String, dynamic>.from(
      (await _request('/api/v1/updates/$core'))['data'] as Map,
    ),
  );
  Future<PanelUpdateInfo> panelUpdate({bool refresh = false}) async =>
      PanelUpdateInfo.fromJson(
        Map<String, dynamic>.from(
          (await _request(
                '/api/v1/panel-update${refresh ? '?refresh=true' : ''}',
              ))['data']
              as Map,
        ),
      );

  Future<void> clearLogs({String instanceId = 'primary'}) async {
    await _request(
      '/api/v1/cores/$instanceId/logs',
      method: 'DELETE',
      payload: {'confirmed': true},
    );
  }

  Future<CoreSettings> coreSettings(String id) async => CoreSettings.fromJson(
    Map<String, dynamic>.from(
      (await _request('/api/v1/cores/$id/settings'))['data'] as Map,
    ),
  );
  Future<PanelSnapshot> saveCoreSettings(
    CoreSettings settings,
    Map<String, String> values,
  ) async => PanelSnapshot.fromJson(
    Map<String, dynamic>.from(
      (await _request(
            '/api/v1/cores/${settings.instanceId}/settings',
            method: 'PUT',
            payload: {'revision': settings.revision, 'values': values},
          ))['data']
          as Map,
    ),
  );

  Future<MaintenanceSnapshot> maintenance() async =>
      MaintenanceSnapshot.fromJson(
        Map<String, dynamic>.from(
          (await _request('/api/v1/maintenance'))['data'] as Map,
        ),
      );
  Future<MaintenanceJob> maintain(
    String action, {
    String? backupId,
    String? tag,
    String? core,
  }) async => MaintenanceJob.fromJson(
    Map<String, dynamic>.from(
      (await _request(
            '/api/v1/maintenance',
            post: true,
            payload: {
              'action': action,
              if (core != null) 'core': core,
              'confirmed': true,
              if (backupId != null) 'backupId': backupId,
              if (tag != null) 'tag': tag,
            },
          ))['data']
          as Map,
    ),
  );

  Future<Map<String, dynamic>> _request(
    String path, {
    bool post = false,
    String? method,
    Map<String, Object?>? payload,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final controller = web.AbortController();
    final timer = Timer(timeout, () => controller.abort());
    try {
      final response = await web.window
          .fetch(
            path.toJS,
            web.RequestInit(
              method: method ?? (post ? 'POST' : 'GET'),
              signal: controller.signal,
              credentials: 'same-origin',
              cache: 'no-store',
              headers:
                  <String, String>{
                        'Content-Type': 'application/json',
                        if (csrfToken != null) 'X-Sky-UI-CSRF': csrfToken!,
                      }.jsify()
                      as JSObject,
              body: (post || payload != null)
                  ? jsonEncode(payload ?? {}).toJS
                  : null,
            ),
          )
          .toDart;
      final data =
          jsonDecode((await response.text().toDart).toDart)
              as Map<String, dynamic>;
      if (!response.ok) {
        final error = data['error'];
        if (response.status == 401 &&
            error is Map &&
            error['code'] == 'auth_required')
          onUnauthorized?.call();
        throw ApiClientException(
          error is Map && error['code'] is String
              ? error['code'] as String
              : 'api_unavailable',
          fields: error is Map
              ? Map<String, String>.from(error['fields'] as Map? ?? {})
              : const {},
        );
      }
      return data;
    } on ApiClientException {
      rethrow;
    } on Object {
      throw const ApiClientException('api_unavailable');
    } finally {
      timer.cancel();
    }
  }

  Future<List<CoreSnapshot>> cores() async =>
      ((await _request('/api/v1/cores'))['data'] as List)
          .map(
            (v) => CoreSnapshot.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList();
  Future<CoreSnapshot> core({String instanceId = 'primary'}) async =>
      CoreSnapshot.fromJson(
        Map<String, dynamic>.from(
          (await _request('/api/v1/cores/$instanceId'))['data'] as Map,
        ),
      );
  Future<List<CoreLogEntry>> logs({String instanceId = 'primary'}) async =>
      ((await _request('/api/v1/cores/$instanceId/logs'))['data'] as List)
          .map(
            (v) => CoreLogEntry.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList();
  Future<CoreSnapshot> execute(
    CoreOperation operation, {
    String instanceId = 'primary',
  }) async => CoreSnapshot.fromJson(
    Map<String, dynamic>.from(
      (await _request(
            '/api/v1/cores/$instanceId/actions/${operation.name}',
            post: true,
          ))['data']
          as Map,
    ),
  );

  Future<PanelSnapshot> panel() async => PanelSnapshot.fromJson(
    Map<String, dynamic>.from((await _request('/api/v1/panel'))['data'] as Map),
  );
  Future<Map<String, dynamic>> sniScan({int? revision, String? cancel}) async =>
      Map<String, dynamic>.from(
        (await _request(
              '/api/v1/connection-tools/sni${cancel == null ? '' : '/$cancel'}',
              method: cancel != null
                  ? 'DELETE'
                  : revision != null
                  ? 'POST'
                  : 'GET',
              payload: cancel != null
                  ? {}
                  : revision != null
                  ? {'revision': revision}
                  : null,
            ))['data']
            as Map,
      );
  Future<Map<String, String>> generateConnectionFields(
    int revision,
    String core,
    String protocol,
    String field,
    Map<String, String> values, {
    String routeId = '',
  }) async => Map<String, String>.from(
    (await _request(
          '/api/v1/connection-tools/generate',
          post: true,
          payload: {
            'revision': revision,
            'core': core,
            'protocol': protocol,
            'field': field,
            'values': values,
            if (routeId.isNotEmpty) 'routeId': routeId,
          },
        ))['data']
        as Map,
  );
  Future<PanelSnapshot> _mutate(
    String path,
    String method,
    Map<String, Object?> payload,
  ) async => PanelSnapshot.fromJson(
    Map<String, dynamic>.from(
      (await _request(
            path,
            method: method,
            payload: payload,
            timeout: const Duration(minutes: 15),
          ))['data']
          as Map,
    ),
  );
  Future<PanelSnapshot> saveConnection(
    int revision,
    Connection value, {
    String? id,
  }) => _mutate(
    '/api/v1/connections${id == null ? '' : '/$id'}',
    id == null ? 'POST' : 'PUT',
    {'revision': revision, 'connection': value.toJson()},
  );
  Future<PanelSnapshot> saveRouting(
    int revision,
    String id,
    String node,
    NodeRouting policy,
  ) => _mutate('/api/v1/connections/$id/routing', 'PUT', {
    'revision': revision,
    'node': node,
    'policy': policy.toJson(),
  });
  Future<PanelSnapshot> saveRecipient(
    int revision,
    Recipient value, {
    String? id,
  }) => _mutate(
    '/api/v1/recipients${id == null ? '' : '/$id'}',
    id == null ? 'POST' : 'PUT',
    {'revision': revision, 'recipient': value.toJson()},
  );
  Future<PanelSnapshot> delete(int revision, String kind, String id) => _mutate(
    '/api/v1/${kind == 'connection' ? 'connections' : 'recipients'}/$id',
    'DELETE',
    {'revision': revision},
  );
  Future<PanelSnapshot> saveSettings(
    int revision,
    String name,
    String address,
  ) => _mutate('/api/v1/settings', 'PUT', {
    'revision': revision,
    'serverName': name,
    'address': address,
  });
  Future<RecipientShare> share(String id) async => RecipientShare.fromJson(
    Map<String, dynamic>.from(
      (await _request('/api/v1/recipients/$id/share'))['data'] as Map,
    ),
  );
}
