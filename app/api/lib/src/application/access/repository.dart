import 'records.dart';

class DeploymentIntent {
  const DeploymentIntent(this.previous, this.candidate, this.wasRunning);
  final String previous;
  final String candidate;
  final bool wasRunning;
}

/// Persistence port used by access workflows and configuration transactions.
abstract interface class AccessRepository {
  int get revision;
  String? get configurationHash;
  DeploymentIntent? get pending;
  String? metadata(String key);
  String? instanceHash(String id);
  String? recipientForToken(String token);
  PanelData read();
  void prepare(DeploymentIntent intent);
  void clearPending();
  void commit(
    PanelData data,
    String configuration, {
    Map<String, String> configurations = const {},
  });
  void close();
}
