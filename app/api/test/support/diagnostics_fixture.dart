import 'dart:async';
import 'dart:io';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/application/connections/diagnostics_service.dart';
import 'package:sky_ui_api/src/application/engines/registry.dart';
import 'package:sky_ui_api/src/application/contracts/connection_diagnostics.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import '../core_manager_test.dart'
    show FakeAdapter, FakeSupervisor, fixtureCore;

class DiagnosticSupervisor extends FakeSupervisor {
  int processId = 42;
  @override
  Future<ServiceObservation> inspect(ManagedCore core) async =>
      ServiceObservation(state, loaded: loaded, processId: processId);
}

class DiagnosticCodec extends MihomoConfiguration {
  @override
  String get coreId => 'test-core';
  ConnectionDiagnosticPlan plan = const ConnectionDiagnosticPlan(
    listeners: [DiagnosticListener(host: '::', port: 35001, udp: false)],
    tls: DiagnosticTlsTarget(
      host: 'handshake.example',
      port: 443,
      serverName: 'sni.example',
      remote: true,
      tls13: true,
    ),
  );
  bool invalid = false;
  @override
  ConnectionDiagnosticPlan diagnosticPlan(
    PanelData data,
    StoredConnection connection,
  ) {
    if (invalid) throw const ApiException('settings_unsupported');
    return plan;
  }
}

class DiagnosticProbe implements DiagnosticNetworkProbe {
  final calls = <String>[];
  DiagnosticProbeResult listenerResult = const DiagnosticProbeResult(
    DiagnosticState.passed,
    'listener_ready',
  );
  DiagnosticProbeResult tlsResult = const DiagnosticProbeResult(
    DiagnosticState.passed,
    'tls_ready',
    {'protocol': 'TLSv1.3', 'cipher': 'TLS_AES_128_GCM_SHA256'},
  );
  DiagnosticProbeResult dnsResult = const DiagnosticProbeResult(
    DiagnosticState.passed,
    'dns_ready',
  );
  Completer<void>? holdTls;
  final enteredTls = Completer<void>();
  @override
  Future<DiagnosticProbeResult> listener(
    DiagnosticListener listener,
    int? pid,
    DiagnosticCancellation cancellation,
  ) async {
    calls.add('listener:${listener.port}:${listener.udp}');
    return listenerResult;
  }

  @override
  Future<DiagnosticResolution> resolve(
    DiagnosticTlsTarget target,
    DiagnosticCancellation cancellation,
  ) async {
    calls.add('dns');
    return DiagnosticResolution(
      dnsResult,
      dnsResult.passed ? ['93.184.215.14'] : [],
    );
  }

  @override
  Future<DiagnosticProbeResult> tcp(
    DiagnosticTlsTarget target,
    List<String> addresses,
    DiagnosticCancellation cancellation,
  ) async {
    calls.add('tcp');
    return DiagnosticProbeResult(DiagnosticState.passed, 'tcp_ready', {
      'address': addresses.first,
    });
  }

  @override
  Future<DiagnosticProbeResult> tls(
    DiagnosticTlsTarget target,
    String address,
    DiagnosticCancellation cancellation,
  ) async {
    calls.add('tls');
    if (!enteredTls.isCompleted) enteredTls.complete();
    if (holdTls != null) {
      void cancel() {
        if (!holdTls!.isCompleted) holdTls!.complete();
      }

      cancellation.add(cancel);
      try {
        await holdTls!.future;
        cancellation.check();
      } finally {
        cancellation.remove(cancel);
      }
    }
    return tlsResult;
  }
}

class DiagnosticsFixture {
  DiagnosticsFixture() {
    work = Directory.systemTemp.createTempSync('sky-ui-diagnostics-');
    repository = PanelRepository(
      '${work.path}/panel.sqlite',
      defaultAddress: 'server.example',
    );
    manager = CoreManager(
      core: fixtureCore(),
      adapters: {adapter.id: adapter},
      supervisor: supervisor,
      stateDirectory: work.path,
    );
    registry = EngineRegistry(
      primary: manager,
      managers: {'primary': manager},
      codecs: {'test-core': codec},
    );
    repository.commit(
      PanelData(
        serverName: 'fixture',
        address: 'server.example',
        connections: [
          const StoredConnection(
            Connection(
              id: 'c_fixture',
              name: 'Private',
              coreId: 'test-core',
              protocolId: 'vless',
              port: 35001,
            ),
            {'privateKey': 'server-private-fixture'},
          ),
        ],
        recipients: [
          const StoredRecipient(
            id: 'u_fixture',
            name: 'Friend',
            enabled: true,
            token: 'recipient-token-fixture',
          ),
        ],
        grants: [
          const AccessGrant(
            id: 'g_fixture',
            recipientId: 'u_fixture',
            connectionId: 'c_fixture',
            credentials: {
              'uuid': 'private-uuid-fixture',
              'password': 'private-password-fixture',
            },
          ),
        ],
      ),
      'native-fixture',
    );
    supervisor.state = CoreProcessState.active;
    service = ConnectionDiagnosticsService(
      registry: registry,
      repository: repository,
      isSynchronized: () async => synchronized,
      probe: probe,
      cooldown: Duration.zero,
      now: () => clock,
    );
  }
  late Directory work;
  late PanelRepository repository;
  final adapter = FakeAdapter();
  final supervisor = DiagnosticSupervisor();
  final codec = DiagnosticCodec();
  final probe = DiagnosticProbe();
  late CoreManager manager;
  late EngineRegistry registry;
  late ConnectionDiagnosticsService service;
  bool synchronized = true;
  DateTime clock = DateTime.utc(2026, 11, 4);
  Future<ConnectionDiagnostics> start() =>
      service.start('c_fixture', repository.revision);
  Future<ConnectionDiagnostics> finish(String id) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    var report = service.get('c_fixture', id);
    while (report.running) {
      if (DateTime.now().isAfter(deadline))
        throw StateError('Diagnostic did not finish');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      report = service.get('c_fixture', id);
    }
    return report;
  }

  Future<void> close() async {
    service.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    repository.close();
    if (work.absolute.parent.uri != Directory.systemTemp.absolute.uri ||
        !work.path
            .split(Platform.pathSeparator)
            .last
            .startsWith('sky-ui-diagnostics-'))
      throw StateError('Unexpected fixture path');
    await work.delete(recursive: true);
  }
}
