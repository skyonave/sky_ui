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
  }) async {
    final controller = web.AbortController();
    final timer = Timer(const Duration(seconds: 90), () => controller.abort());
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
  Future<PanelSnapshot> _mutate(
    String path,
    String method,
    Map<String, Object?> payload,
  ) async => PanelSnapshot.fromJson(
    Map<String, dynamic>.from(
      (await _request(path, method: method, payload: payload))['data'] as Map,
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
