import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../engines/managed_core.dart';
import '../access/records.dart';

/// Optional capability. Native settings stay inside the owning adapter.
abstract interface class CoreSettingsCodec {
  List<ProtocolField> get coreSettingsFields;
  Map<String, String> readCoreSettings(
    String native,
    Map<String, String>? stored,
  );
  Map<String, String> prepareCoreSettings(
    String native,
    Map<String, String>? stored,
    Map<String, String> input,
  );
}

/// Protocols with per-recipient address/resource allocation opt in explicitly.
abstract interface class DeviceGrantPolicy {
  bool requiresDeviceGrant(StoredConnection connection);
}

abstract interface class GrantAllocator {
  Map<String, String> allocateGrant(
    PanelData data,
    StoredConnection connection,
    Map<String, String> credentials,
  );
}

abstract interface class ConfigurationCodec {
  String get coreId;
  List<ProtocolDefinition> get protocols;
  Map<String, String> validateSettings(Connection connection);
  Future<Map<String, String>> connectionSecrets(
    Connection connection, {
    Map<String, String> previous = const {},
  });
  Future<Map<String, String>> grantCredentials(
    StoredConnection connection, {
    Map<String, String> previous = const {},
  });
  String compile(
    PanelData data,
    ManagedCore core,
    String previous, {
    bool validationOnly = false,
  });
  Future<void> verifyRunning(PanelData data, ManagedCore core);
  Future<void> preflight(PanelData before, PanelData after, bool running);
  ClientEndpoint clientEndpoint(
    StoredConnection connection,
    AccessGrant grant,
    String address,
  );
}
