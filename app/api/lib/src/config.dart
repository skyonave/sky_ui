import 'dart:io';

final skyUiVersion = _bundleVersion();
String _bundleVersion() {
  const defined = String.fromEnvironment('SKY_UI_VERSION');
  if (defined.isNotEmpty) return defined;
  final root = File(Platform.resolvedExecutable).parent.parent;
  if (File('${root.path}/ARCH').existsSync() &&
      File('${root.path}/VERSION').existsSync()) {
    final value = File('${root.path}/VERSION').readAsStringSync().trim();
    if (RegExp(r'^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.]+)?$').hasMatch(value))
      return value;
  }
  return '0.8.0-dev.4';
}

class ServerConfig {
  ServerConfig({
    required this.port,
    required this.webOrigin,
    required this.publicDirectory,
    required this.dataDirectory,
    required this.core,
    this.additionalOrigins = const [],
    this.gatewaySecret = '',
    this.ownerSeedFile,
    this.requireOwnerAuth = true,
    this.certificatesDirectory = '/var/lib/sky-ui-certificates',
    this.networkAdministration = false,
  });
  final int port;
  final Uri webOrigin;
  final List<Uri> additionalOrigins;
  Set<String> get allowedOrigins => {
    webOrigin.origin,
    ...additionalOrigins.map((v) => v.origin),
  };
  final String publicDirectory;
  final String dataDirectory;
  final ManagedCore core;
  final String gatewaySecret;
  final String? ownerSeedFile;
  final bool requireOwnerAuth;
  final String certificatesDirectory;
  final bool networkAdministration;

  List<ManagedCore> get proxyCores => [
    for (final id in ['sing-box', 'xray', 'amneziawg'])
      ManagedCore(
        id: id,
        coreId: id,
        service: 'sky-ui-$id.service',
        binary: '/opt/sky-ui/cores/$id/current/$id',
        directory: '$dataDirectory/cores/$id',
        configuration: '$dataDirectory/cores/$id/config.json',
        // No control socket is exposed for engines that do not need one.
        controller: Uri.parse('http://127.0.0.1:0'),
        secret: '',
      ),
  ];

  static Future<ServerConfig> fromEnvironment([
    Map<String, String>? environment,
  ]) async {
    final env = environment ?? Platform.environment;
    final host = env['SKY_UI_HOST'] ?? '127.0.0.1';
    if (host != '127.0.0.1') {
      throw const FormatException(
        'Only 127.0.0.1 is supported until owner authentication is implemented.',
      );
    }
    final port = int.parse(env['SKY_UI_PORT'] ?? '39242');
    if (port < 1 || port > 65535)
      throw const FormatException('Invalid API port.');
    final origin = Uri.parse(
      env['SKY_UI_WEB_ORIGIN'] ?? 'http://127.0.0.1:$port',
    );
    if (!((origin.scheme == 'http' && origin.host == '127.0.0.1') ||
            (origin.scheme == 'https' && origin.host.isNotEmpty)) ||
        origin.userInfo.isNotEmpty ||
        origin.hasQuery ||
        origin.hasFragment ||
        (origin.path.isNotEmpty && origin.path != '/')) {
      throw const FormatException(
        'The web origin must be loopback HTTP or an explicit HTTPS origin behind the authenticated gateway.',
      );
    }
    final extraOrigin = env['SKY_UI_EXTRA_ORIGIN'];
    final additionalOrigins = extraOrigin == null || extraOrigin.isEmpty
        ? <Uri>[]
        : [Uri.parse(extraOrigin)];
    for (final extra in additionalOrigins) {
      if (extra.scheme != 'https' ||
          extra.host.isEmpty ||
          extra.userInfo.isNotEmpty ||
          extra.hasQuery ||
          extra.hasFragment ||
          (extra.path.isNotEmpty && extra.path != '/')) {
        throw const FormatException('Invalid additional HTTPS origin.');
      }
    }
    final secretPath = env['SKY_UI_CONTROLLER_SECRET_FILE'];
    final gatewayPath = env['SKY_UI_GATEWAY_SECRET_FILE'];
    final gatewaySecret = gatewayPath == null
        ? ''
        : (await File(gatewayPath).readAsString()).trim();
    if ((origin.scheme == 'https' || gatewayPath != null) &&
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(gatewaySecret)) {
      throw const FormatException(
        'Public access requires a private gateway credential file.',
      );
    }
    final secret = secretPath == null
        ? ''
        : (await File(secretPath).readAsString()).trim();
    final controller = Uri.parse(
      env['SKY_UI_CONTROLLER_URL'] ?? 'http://127.0.0.1:19090',
    );
    if (controller.scheme != 'http' ||
        controller.host != '127.0.0.1' ||
        controller.userInfo.isNotEmpty ||
        controller.hasQuery ||
        controller.hasFragment ||
        (controller.path.isNotEmpty && controller.path != '/')) {
      throw const FormatException('Controller must use loopback HTTP.');
    }
    return ServerConfig(
      port: port,
      webOrigin: origin,
      additionalOrigins: additionalOrigins,
      gatewaySecret: gatewaySecret,
      ownerSeedFile: env['SKY_UI_OWNER_SEED_FILE'],
      certificatesDirectory:
          env['SKY_UI_CERTIFICATES_DIR'] ?? '/var/lib/sky-ui-certificates',
      networkAdministration: env['SKY_UI_NETWORK_ADMINISTRATION'] == 'enabled',
      publicDirectory: env['SKY_UI_PUBLIC_DIR'] ?? '../web/build/web',
      dataDirectory: env['SKY_UI_DATA_DIR'] ?? '../../runtime/api',
      core: ManagedCore(
        id: 'primary',
        coreId: 'mihomo',
        service: 'sky-ui-mihomo.service',
        binary:
            env['SKY_UI_CORE_BINARY'] ??
            '/opt/sky-ui/cores/mihomo/current/mihomo',
        directory:
            env['SKY_UI_CORE_DIRECTORY'] ?? '/var/lib/sky-ui/cores/mihomo',
        configuration:
            env['SKY_UI_CORE_CONFIG'] ??
            '/var/lib/sky-ui/cores/mihomo/config.yaml',
        controller: controller,
        secret: secret,
      ),
    );
  }
}

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
