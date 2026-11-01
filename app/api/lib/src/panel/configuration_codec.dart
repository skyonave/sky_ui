import 'package:sky_ui_shared/sky_ui_shared.dart';
import '../config.dart';
import 'domain.dart';

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
