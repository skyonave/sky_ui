import 'package:dart_frog/dart_frog.dart';

import '../../application/engines/core_manager.dart';
import '../../features/updates/core_updates.dart';
import '../../features/updates/panel_updates.dart';

void registerPanelUpdateRoutes(Router router, PanelUpdates applicationUpdates) {
  router.get(
    '/api/v1/panel-update',
    (context) async => Response.json(
      body: {
        'data': (await applicationUpdates.get(
          refresh: context.request.uri.queryParameters['refresh'] == 'true',
        )).toJson(),
      },
    ),
  );
}

void registerCoreUpdateRoutes(
  Router router,
  Map<String, CoreManager> instances,
  CoreUpdates updates,
) {
  router.get('/api/v1/updates/<core>', (
    RequestContext context,
    String core,
  ) async {
    final owner = instances.values
        .where((m) => m.core.coreId == core)
        .firstOrNull;
    final installed = owner == null ? null : (await owner.snapshot()).version;
    return Response.json(
      body: {'data': (await updates.get(core, installed)).toJson()},
    );
  });
}
