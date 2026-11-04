import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';

import '../../application/access/panel_service.dart';
import '../../application/engines/core_manager.dart';
import '../../application/logs/panel_log.dart';
import '../../features/maintenance/service.dart';
import '../../features/updates/core_updates.dart';
import '../../features/updates/panel_updates.dart';
import '../../shared/api_exception.dart';

void registerMaintenanceRoutes(
  Router router,
  CoreManager manager,
  Map<String, CoreManager> instances,
  MaintenanceService maintenance,
  CoreUpdates updates,
  PanelUpdates applicationUpdates,
  PanelService? panel,
  PanelLog log,
) {
  ({String id, String status, String? stage})? observed;
  router.get('/api/v1/maintenance', (_) async {
    final snapshot = await maintenance.snapshot();
    final job = snapshot.job;
    if (job != null) {
      final stage = job.progress?.stage;
      final current = (id: job.id, status: job.status, stage: stage);
      if (current != observed) {
        observed = current;
        final code = RegExp(r'^[a-z][a-z0-9_-]{0,47}$');
        if (MaintenanceService.idPattern.hasMatch(job.id) &&
            code.hasMatch(job.action) &&
            code.hasMatch(job.status) &&
            (stage == null || code.hasMatch(stage))) {
          log.event(
            'Maintenance ${job.id.substring(0, 8)} ${job.action} ${job.status}'
            '${stage == null ? '' : ' $stage'}',
            level: job.status == 'failed' ? 'error' : 'info',
          );
        }
      }
    }
    return Response.json(body: {'data': snapshot.toJson()});
  });
  router.post('/api/v1/maintenance', (context) async {
    if ((context.request.headers['content-type'] ?? '')
            .split(';')
            .first
            .trim() !=
        'application/json') {
      throw const ApiException('json_required', status: 415);
    }
    final bytes = <int>[];
    await for (final chunk in context.request.bytes()) {
      if (bytes.length + chunk.length > 4096)
        throw const ApiException('request_too_large', status: 413);
      bytes.addAll(chunk);
    }
    Map<String, dynamic> value;
    try {
      value = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } on Object {
      throw const ApiException('request_invalid', status: 400);
    }
    if (value['confirmed'] != true ||
        value['action'] is! String ||
        (value['backupId'] != null && value['backupId'] is! String) ||
        (value['core'] != null && value['core'] is! String) ||
        (value['tag'] != null && value['tag'] is! String)) {
      throw const ApiException('request_invalid', status: 400);
    }
    final selectedCore = value['core'] as String? ?? manager.core.coreId;
    final selectedManager = instances.values
        .where((m) => m.core.coreId == selectedCore)
        .firstOrNull;
    if (selectedManager == null)
      throw const ApiException('core_unsupported', status: 422);
    final job = await selectedManager.exclusive((_) async {
      if (panel != null && !await panel.isSynchronized()) {
        throw const ApiException('configuration_out_of_sync', status: 409);
      }
      if (value['action'] == 'panel-update') {
        await applicationUpdates.requireApproved(value['tag'] as String? ?? '');
      }
      if (['remove', 'install'].contains(value['action'])) {
        final installed = (await selectedManager.snapshot()).binaryAvailable;
        if (installed == (value['action'] == 'install')) {
          throw ApiException(
            installed ? 'core_already_installed' : 'binary_missing',
            status: 409,
          );
        }
      }
      if (['update', 'install'].contains(value['action'])) {
        await updates.requireApproved(
          selectedCore,
          value['tag'] as String? ?? '',
        );
      }
      return maintenance.submit(
        value['action'] as String,
        backupId: value['backupId'] as String?,
        core: ['update', 'install', 'remove'].contains(value['action'])
            ? selectedCore
            : null,
        tag: value['tag'] as String?,
      );
    });
    return Response.json(statusCode: 202, body: {'data': job.toJson()});
  });
  router.get('/api/v1/backups/<id>/download', (
    RequestContext context,
    String id,
  ) async {
    final file = await maintenance.archive(id);
    return Response.stream(
      body: file.openRead(),
      headers: {
        'content-type': 'application/gzip',
        'content-disposition': 'attachment; filename=sky-ui-$id.tar.gz',
      },
    );
  });
}
