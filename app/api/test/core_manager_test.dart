import 'dart:async';
import 'dart:io';
import 'package:sky_ui_api/sky_ui_api.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';

class FakeAdapter implements CoreAdapter {
  bool invalid = false;
  bool ready = true;
  final calls = <String>[];
  @override
  String get id => 'test-core';
  @override
  String get name => 'Test core';
  @override
  List<CoreLogEntry> get logs => bufferedLogs;
  final bufferedLogs = <CoreLogEntry>[];
  @override
  void clearLogs() => bufferedLogs.clear();
  @override
  Future<BinaryProbe> probe(ManagedCore core) async =>
      const BinaryProbe(true, '1.0.0');
  @override
  Future<void> validate(ManagedCore core) async {
    calls.add('validate');
    if (invalid) throw const ApiException('configuration_invalid', status: 422);
  }

  @override
  Future<bool> controllerReady(ManagedCore core) async => ready;
  @override
  Future<void> observeLogs(ManagedCore core) async {}
  @override
  Future<void> close() async {}
}

class FakeSupervisor implements ProcessSupervisor {
  @override
  bool supported = true;
  bool loaded = true;
  CoreProcessState state = CoreProcessState.inactive;
  final calls = <String>[];
  int concurrent = 0;
  int peak = 0;
  @override
  Future<ServiceObservation> inspect(ManagedCore core) async =>
      ServiceObservation(state, loaded: loaded);
  @override
  Future<void> execute(ManagedCore core, CoreOperation operation) async {
    concurrent++;
    if (concurrent > peak) peak = concurrent;
    calls.add(operation.name);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    state = operation == CoreOperation.stop
        ? CoreProcessState.inactive
        : CoreProcessState.active;
    concurrent--;
  }
}

ManagedCore fixtureCore() => ManagedCore(
  id: 'primary',
  coreId: 'test-core',
  service: 'sky-ui-test.service',
  binary: '/unused',
  directory: '/unused',
  configuration: '/unused',
  controller: Uri.parse('http://127.0.0.1:19090'),
  secret: 'not-a-real-secret',
);
void main() {
  late Directory directory;
  late FakeAdapter adapter;
  late FakeSupervisor supervisor;
  late CoreManager manager;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sky-ui-test-');
    adapter = FakeAdapter();
    supervisor = FakeSupervisor();
    manager = CoreManager(
      core: fixtureCore(),
      adapters: {adapter.id: adapter},
      supervisor: supervisor,
      stateDirectory: directory.path,
      readyTimeout: const Duration(milliseconds: 20),
    );
  });
  tearDown(() async => directory.delete(recursive: true));
  test('invalid configuration never restarts a running process', () async {
    adapter.invalid = true;
    supervisor.state = CoreProcessState.active;
    await expectLater(
      manager.execute(CoreOperation.restart),
      throwsA(
        isA<ApiException>().having(
          (v) => v.code,
          'code',
          'configuration_invalid',
        ),
      ),
    );
    expect(supervisor.calls, isEmpty);
    expect(supervisor.state, CoreProcessState.active);
    expect(manager.desired, CoreDesiredState.unknown);
  });
  test('failed operation does not poison the serialized queue', () async {
    adapter.invalid = true;
    await expectLater(
      manager.execute(CoreOperation.start),
      throwsA(isA<ApiException>()),
    );
    adapter.invalid = false;
    final value = await manager.execute(CoreOperation.start);
    expect(value.controllerReady, true);
    expect(adapter.calls, ['validate', 'validate']);
  });
  test('conflicting lifecycle operations are serialized', () async {
    await Future.wait([
      manager.execute(CoreOperation.start),
      manager.execute(CoreOperation.stop),
      manager.execute(CoreOperation.start),
    ]);
    expect(supervisor.calls, ['start', 'stop', 'start']);
    expect(supervisor.peak, 1);
    final restored = CoreManager(
      core: fixtureCore(),
      adapters: {adapter.id: adapter},
      supervisor: supervisor,
      stateDirectory: directory.path,
    );
    await restored.initialize();
    expect(restored.desired, CoreDesiredState.running);
    supervisor.state = CoreProcessState.inactive;
    await restored.restore();
    expect(supervisor.state, CoreProcessState.active);
  });
  test(
    'active process with unready controller is reported separately',
    () async {
      adapter.ready = false;
      await expectLater(
        manager.execute(CoreOperation.start),
        throwsA(
          isA<ApiException>().having(
            (v) => v.code,
            'code',
            'controller_not_ready',
          ),
        ),
      );
      final value = await manager.snapshot();
      expect(value.processState, CoreProcessState.active);
      expect(value.controllerReady, false);
      expect(value.desiredState, CoreDesiredState.running);
    },
  );
  test('unsupported platform never invokes lifecycle controls', () async {
    supervisor.supported = false;
    await expectLater(
      manager.execute(CoreOperation.start),
      throwsA(
        isA<ApiException>().having(
          (v) => v.code,
          'code',
          'platform_unsupported',
        ),
      ),
    );
    expect(supervisor.calls, isEmpty);
  });
  test('missing managed service is never controlled', () async {
    supervisor.loaded = false;
    await expectLater(
      manager.execute(CoreOperation.stop),
      throwsA(
        isA<ApiException>().having((v) => v.code, 'code', 'service_missing'),
      ),
    );
    expect(supervisor.calls, isEmpty);
  });
}
