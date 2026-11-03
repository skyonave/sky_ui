class ManagedCore {
  const ManagedCore({
    required this.id,
    required this.coreId,
    required this.service,
    required this.binary,
    required this.directory,
    required this.configuration,
    required this.controller,
    required this.secret,
  });
  final String id;
  final String coreId;
  final String service;
  final String binary;
  final String directory;
  final String configuration;
  final Uri controller;
  final String secret;
  ManagedCore withConfiguration(String path) => ManagedCore(
    id: id,
    coreId: coreId,
    service: service,
    binary: binary,
    directory: directory,
    configuration: path,
    controller: controller,
    secret: secret,
  );
}
