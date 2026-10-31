import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:web/web.dart' as web;

class ApiClientException implements Exception {
  const ApiClientException(this.code);
  final String code;
}

class ApiClient {
  Future<SystemSnapshot> system() async => SystemSnapshot.fromJson(
    Map<String, dynamic>.from(
      (await _request('/api/v1/system'))['data'] as Map,
    ),
  );
  Future<CoreReleaseNotes> releases(String core) async =>
      CoreReleaseNotes.fromJson(
        Map<String, dynamic>.from(
          (await _request('/api/v1/releases/$core'))['data'] as Map,
        ),
      );
  Future<void> clearLogs() async {
    await _request(
      '/api/v1/cores/primary/logs',
      method: 'DELETE',
      payload: {'confirmed': true},
    );
  }

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
                  <String, String>{'Content-Type': 'application/json'}.jsify()
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
        throw ApiClientException(
          error is Map && error['code'] is String
              ? error['code'] as String
              : 'api_unavailable',
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

  Future<CoreSnapshot> core() async => CoreSnapshot.fromJson(
    Map<String, dynamic>.from(
      (await _request('/api/v1/cores/primary'))['data'] as Map,
    ),
  );
  Future<List<CoreLogEntry>> logs() async =>
      ((await _request('/api/v1/cores/primary/logs'))['data'] as List)
          .map(
            (v) => CoreLogEntry.fromJson(Map<String, dynamic>.from(v as Map)),
          )
          .toList();
  Future<CoreSnapshot> execute(CoreOperation operation) async =>
      CoreSnapshot.fromJson(
        Map<String, dynamic>.from(
          (await _request(
                '/api/v1/cores/primary/actions/${operation.name}',
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
