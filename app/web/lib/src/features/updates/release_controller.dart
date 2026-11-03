import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/api/api_client.dart';
import '../../shared/protocols/catalog.dart';

/// Release discovery cache is independent of the app's polling and dialog UI.
class ReleaseController {
  ReleaseController({
    required this.api,
    required this.isAlive,
    required this.onChanged,
  });
  final ApiClient api;
  final bool Function() isAlive;
  final void Function() onChanged;
  bool get mounted => isAlive();
  void _change(void Function() update) {
    if (!mounted) return;
    update();
    onChanged();
  }

  CoreUpdateInfo? coreUpdates;
  PanelUpdateInfo? panelUpdateInfo;
  bool panelUpdateLoading = false;
  bool panelUpdateManualChecked = false;
  String? panelUpdateError;
  DateTime? panelUpdateChecked;
  bool updatesLoading = false;
  String? updatesError;
  final engineUpdates = <String, CoreUpdateInfo>{};
  Future<void> refreshPanelUpdate({bool refresh = false}) async {
    if (panelUpdateLoading) return;
    _change(() {
      panelUpdateLoading = true;
      if (refresh) panelUpdateManualChecked = false;
    });
    try {
      final value = await api.panelUpdate(refresh: refresh);
      if (mounted)
        _change(() {
          panelUpdateInfo = value;
          panelUpdateError = null;
          if (refresh) panelUpdateManualChecked = true;
        });
    } on ApiClientException catch (e) {
      if (mounted) _change(() => panelUpdateError = e.code);
    } finally {
      panelUpdateChecked = DateTime.now();
      if (mounted) _change(() => panelUpdateLoading = false);
    }
  }

  Future<void> refreshCoreUpdates() async {
    if (updatesLoading) return;
    updatesLoading = true;
    try {
      final values = await Future.wait(
        coreCatalog.map((c) async {
          try {
            return await api.updates(c.id);
          } on ApiClientException {
            return null;
          }
        }),
      );
      if (mounted)
        _change(() {
          engineUpdates.clear();
          for (final value in values.whereType<CoreUpdateInfo>()) {
            engineUpdates[value.coreId] = value;
          }
          coreUpdates = engineUpdates['mihomo'];
          updatesError = null;
        });
    } on ApiClientException catch (e) {
      if (mounted)
        _change(() {
          coreUpdates = null;
          updatesError = e.code;
        });
    } finally {
      if (mounted) _change(() => updatesLoading = false);
    }
  }
}
