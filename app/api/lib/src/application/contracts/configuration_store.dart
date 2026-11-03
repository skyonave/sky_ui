import '../../engines/managed_core.dart';

/// Native document persistence; callers never need a filesystem handle.
abstract interface class ConfigurationStore {
  Future<String?> read(ManagedCore core);
  Future<bool> matches(ManagedCore core, String expectedHash);
  Future<T> stage<T>(
    String text,
    String name,
    Future<T> Function(String path) action,
  );
  Future<void> publish(String text, ManagedCore core);
}
