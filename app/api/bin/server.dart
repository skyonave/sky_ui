import 'dart:async';
import 'dart:io';
import 'package:dart_frog/dart_frog.dart';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/auth/owner_auth.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--version')) {
    stdout.writeln('Sky UI $skyUiVersion');
    return;
  }
  final config = await ServerConfig.fromEnvironment();
  final runner = NativeCommandRunner(
    environment: {'SAFE_PATHS': config.certificatesDirectory},
  );
  final adapter = MihomoAdapter(runner);
  final supervisor = SystemdSupervisor(runner);
  final manager = CoreManager(
    core: config.core,
    adapters: {adapter.id: adapter},
    supervisor: supervisor,
    stateDirectory: '${config.dataDirectory}/instances',
  );
  await manager.initialize();
  await Directory(config.dataDirectory).create(recursive: true);
  final ownerAuth = OwnerAuth(
    '${config.dataDirectory}/owner.sqlite',
    secure: config.webOrigin.scheme == 'https',
  );
  await ownerAuth.initialize(config.ownerSeedFile);
  final repository = PanelRepository(
    '${config.dataDirectory}/panel.sqlite',
    defaultAddress: config.webOrigin.host,
  );
  final codec = MihomoConfiguration(
    supervisor: supervisor,
    core: config.core,
    runner: runner,
    certificatesDirectory: config.certificatesDirectory,
    publicAddress: config.webOrigin.host,
    networkAdministration: config.networkAdministration,
  );
  final panel = PanelService(
    config: config,
    manager: manager,
    repository: repository,
    codecs: {codec.coreId: codec},
    exporter: ClashExporter(),
  );
  await panel.initialize();
  final server = await serve(
    createApplication(config, manager, panel: panel, auth: ownerAuth),
    InternetAddress.loopbackIPv4,
    config.port,
    poweredByHeader: null,
  );
  stdout.writeln('Sky UI API: http://127.0.0.1:${server.port}');
  var refreshing = false;
  Future<void> refresh() async {
    if (refreshing) return;
    refreshing = true;
    try {
      await manager.snapshot();
    } on Object {
      stderr.writeln('Core observation failed.');
    } finally {
      refreshing = false;
    }
  }

  unawaited(refresh());
  unawaited(
    panel.restoreCore().catchError((Object _) {
      stderr.writeln(
        'Managed core state could not be restored; inspect the API status.',
      );
    }),
  );
  final timer = Timer.periodic(
    const Duration(seconds: 5),
    (_) => unawaited(refresh()),
  );
  Future<void> shutdown() async {
    timer.cancel();
    await server.close(force: true);
    await manager.exclusive((_) async {});
    await adapter.close();
    repository.close();
    ownerAuth.close();
  }

  ProcessSignal.sigint.watch().listen((_) async {
    await shutdown();
    exit(0);
  });
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) async {
      await shutdown();
      exit(0);
    });
  }
}
