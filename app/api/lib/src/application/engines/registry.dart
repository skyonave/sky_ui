import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/api_exception.dart';
import '../contracts/configuration_codec.dart';
import 'core_manager.dart';

class EngineRegistry {
  EngineRegistry({
    required this.primary,
    required this.managers,
    required this.codecs,
  });
  final CoreManager primary;
  final Map<String, CoreManager> managers;
  final Map<String, ConfigurationCodec> codecs;
  ConfigurationCodec codec(String id) =>
      codecs[id] ?? (throw const ApiException('core_unsupported', status: 422));
  CoreManager owner(Connection connection) {
    final owner = managers[connection.instanceId];
    if (owner == null || owner.core.coreId != connection.coreId)
      throw const ApiException('core_unavailable', status: 422);
    return owner;
  }

  Future<T> exclusive<T>(Future<T> Function(Map<String, CoreControl>) action) {
    final ordered = managers.keys.toList()..sort();
    final controls = <String, CoreControl>{};
    Future<T> lock(int index) => index == ordered.length
        ? action(controls)
        : managers[ordered[index]]!.exclusive((control) {
            controls[ordered[index]] = control;
            return lock(index + 1);
          });
    return lock(0);
  }
}
