import 'dart:async';
import 'dart:convert';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_api/src/application/connections/diagnostics_service.dart';
import 'package:sky_ui_api/src/application/contracts/connection_diagnostics.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';
import 'support/diagnostics_fixture.dart';

void main() {
  late DiagnosticsFixture fixture;
  setUp(() => fixture = DiagnosticsFixture());
  tearDown(() => fixture.close());
  DiagnosticCheck step(ConnectionDiagnostics report, String id) =>
      report.checks.singleWhere((check) => check.id == id);
  test(
    'reports scoped stages without writes, lifecycle changes or credential disclosure',
    () async {
      final revision = fixture.repository.revision,
          previous = jsonEncode(
            fixture.repository
                .read()
                .connections
                .map((c) => c.value.toJson())
                .toList(),
          );
      final initial = await fixture.start(),
          report = await fixture.finish(initial.id);
      expect(report.outcome, 'passed');
      expect(report.completed, report.checks.length);
      expect(step(report, 'tls').details['protocol'], 'TLSv1.3');
      expect(fixture.repository.revision, revision);
      expect(
        jsonEncode(
          fixture.repository
              .read()
              .connections
              .map((c) => c.value.toJson())
              .toList(),
        ),
        previous,
      );
      expect(fixture.supervisor.calls, isEmpty);
      expect(fixture.adapter.calls, ['validate']);
      final json = jsonEncode(report.toJson());
      for (final secret in [
        'server-private-fixture',
        'recipient-token-fixture',
        'private-uuid-fixture',
        'private-password-fixture',
        fixture.manager.core.secret,
      ]) {
        expect(json, isNot(contains(secret)));
      }
      expect(
        ConnectionDiagnostics.fromJson(
          jsonDecode(json) as Map<String, dynamic>,
        ).toJson(),
        report.toJson(),
      );
    },
  );
  test(
    'stopped engine is explicit while independent handshake target can still be checked',
    () async {
      fixture.supervisor.state = CoreProcessState.inactive;
      final report = await fixture.finish((await fixture.start()).id);
      expect(step(report, 'engine').code, 'core_stopped');
      expect(step(report, 'listener.0').state, DiagnosticState.skipped);
      expect(step(report, 'tls').state, DiagnosticState.passed);
      expect(report.outcome, 'failed');
    },
  );
  test('missing binary does not invoke its validator', () async {
    fixture.adapter.available = false;
    final report = await fixture.finish((await fixture.start()).id);
    expect(step(report, 'engine').code, 'binary_missing');
    expect(step(report, 'native').state, DiagnosticState.skipped);
    expect(fixture.adapter.calls, isEmpty);
  });
  test('native rejection is visible without an automatic restart', () async {
    fixture.adapter.invalid = true;
    final report = await fixture.finish((await fixture.start()).id);
    expect(step(report, 'native').code, 'native_invalid');
    expect(fixture.supervisor.calls, isEmpty);
  });
  test('unsynchronized configuration blocks network probes', () async {
    fixture.synchronized = false;
    final report = await fixture.finish((await fixture.start()).id);
    expect(step(report, 'configuration').code, 'configuration_out_of_sync');
    expect(fixture.probe.calls, isEmpty);
  });
  test(
    'invalid stored form is a report failure, not an uninformative API failure',
    () async {
      fixture.codec.invalid = true;
      final report = await fixture.finish((await fixture.start()).id);
      expect(step(report, 'configuration').code, 'settings_invalid');
      expect(report.outcome, 'failed');
    },
  );
  test('disabled recipient is not counted as active access', () async {
    final data = fixture.repository.read();
    data.recipients[0] = const StoredRecipient(
      id: 'u_fixture',
      name: 'Friend',
      enabled: false,
      token: 'recipient-token-fixture',
    );
    fixture.repository.commit(data, 'native-fixture');
    final report = await fixture.finish((await fixture.start()).id);
    expect(step(report, 'access').code, 'no_recipients');
  });
  test(
    'UDP protocol reports a socket without inventing a TLS handshake',
    () async {
      fixture.codec.plan = const ConnectionDiagnosticPlan(
        listeners: [DiagnosticListener(host: '::', port: 35001, udp: true)],
        tlsSkipCode: 'quic_client_required',
      );
      final report = await fixture.finish((await fixture.start()).id);
      expect(fixture.probe.calls, ['listener:35001:true']);
      expect(step(report, 'tls').state, DiagnosticState.skipped);
      expect(step(report, 'tls').code, 'quic_client_required');
    },
  );
  test(
    'foreign or missing listener cannot be used as a local TLS success',
    () async {
      fixture.codec.plan = const ConnectionDiagnosticPlan(
        listeners: [DiagnosticListener(host: '::', port: 35001, udp: false)],
        tls: DiagnosticTlsTarget(
          host: '::1',
          port: 35001,
          serverName: 'panel.example',
          remote: false,
        ),
      );
      fixture.probe.listenerResult = const DiagnosticProbeResult(
        DiagnosticState.failed,
        'listener_missing',
      );
      final report = await fixture.finish((await fixture.start()).id);
      expect(fixture.probe.calls, ['listener:35001:false']);
      expect(step(report, 'tls').state, DiagnosticState.skipped);
    },
  );
  test('DNS failure prevents TCP and TLS probes', () async {
    fixture.probe.dnsResult = const DiagnosticProbeResult(
      DiagnosticState.failed,
      'dns_failed',
    );
    final report = await fixture.finish((await fixture.start()).id);
    expect(fixture.probe.calls, isNot(contains('tcp')));
    expect(step(report, 'dns').code, 'dns_failed');
  });
  test(
    'concurrency is bounded and cancellation terminates owned probes',
    () async {
      fixture.probe.holdTls = Completer<void>();
      final run = await fixture.start();
      await fixture.probe.enteredTls.future;
      expect((await fixture.start()).id, run.id);
      await expectLater(
        fixture.service.start('other', fixture.repository.revision),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'diagnostics_busy'),
        ),
      );
      final result = fixture.service.cancel('c_fixture', run.id);
      expect(result.status, 'cancelled');
      expect(fixture.probe.holdTls!.isCompleted, isTrue);
      expect(
        result.checks.any((c) => c.state == DiagnosticState.running),
        isFalse,
      );
    },
  );
  test('configuration or process changes invalidate the report', () async {
    fixture.probe.holdTls = Completer<void>();
    final run = await fixture.start();
    await fixture.probe.enteredTls.future;
    fixture.repository.commit(fixture.repository.read(), 'changed');
    fixture.supervisor.processId++;
    fixture.probe.holdTls!.complete();
    final report = await fixture.finish(run.id);
    expect(step(report, 'freshness').code, 'state_changed');
    expect(report.outcome, 'warning');
  });
  test(
    'outdated requests and wrong connection/job pairs fail closed',
    () async {
      await expectLater(
        fixture.service.start('c_fixture', 0),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'state_changed'),
        ),
      );
      final run = await fixture.start();
      await fixture.finish(run.id);
      expect(
        () => fixture.service.get('other', run.id),
        throwsA(isA<ApiException>()),
      );
      expect(
        () => fixture.service.cancel('other', run.id),
        throwsA(isA<ApiException>()),
      );
    },
  );
  test('durable rollback barrier cannot be bypassed by diagnostics', () async {
    fixture.repository.prepare(
      const DeploymentIntent('before', 'after', false),
    );
    await expectLater(
      fixture.start(),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          'configuration_rollback_failed',
        ),
      ),
    );
    expect(fixture.probe.calls, isEmpty);
  });
  test('expired reports are removed', () async {
    final run = await fixture.start();
    await fixture.finish(run.id);
    fixture.clock = fixture.clock.add(const Duration(minutes: 6));
    expect(
      () => fixture.service.get('c_fixture', run.id),
      throwsA(isA<ApiException>()),
    );
  });
  test('deadline cannot leave a pending report looking successful', () async {
    fixture.service.dispose();
    fixture.service = ConnectionDiagnosticsService(
      registry: fixture.registry,
      repository: fixture.repository,
      isSynchronized: () async => true,
      probe: fixture.probe,
      deadline: const Duration(milliseconds: 30),
    );
    fixture.probe.holdTls = Completer<void>();
    final run = await fixture.start(), report = await fixture.finish(run.id);
    expect(report.outcome, 'failed');
    expect(report.checks.any((c) => c.code == 'diagnostic_timeout'), isTrue);
  });
}
