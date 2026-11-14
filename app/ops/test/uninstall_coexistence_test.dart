import 'dart:io';

import 'package:sky_ui_ops/src/cli/uninstall.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late File backup, forwarding;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sky-ui-uninstall-test-');
    backup = File('${root.path}/previous');
    forwarding = File('${root.path}/current');
    await backup.writeAsString('0\n');
    await forwarding.writeAsString('1\n');
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'panel uninstall leaves a live or uncertain node forwarding enabled',
    () async {
      for (final state in <String?>[
        'active',
        'activating',
        'reloading',
        'deactivating',
        'failed',
        null,
      ]) {
        expect(
          await restorePanelForwarding(backup, forwarding, () async => state),
          isFalse,
        );
        expect(await forwarding.readAsString(), '1\n', reason: '$state');
      }
    },
  );

  test(
    'panel-only uninstall and a stopped node restore the original value',
    () async {
      for (final state in ['not-installed', 'inactive']) {
        await forwarding.writeAsString('1\n');
        expect(
          await restorePanelForwarding(backup, forwarding, () async => state),
          isTrue,
        );
        expect(await forwarding.readAsString(), '0\n');
      }
    },
  );

  test('uninstall preserves an independent forwarding change', () async {
    await forwarding.writeAsString('0\n');
    await backup.writeAsString('1\n');
    expect(
      await restorePanelForwarding(backup, forwarding, () async => 'inactive'),
      isFalse,
    );
    expect(await forwarding.readAsString(), '0\n');
  });

  test('a retained node keeps its shared AWG compiler account', () {
    expect(
      panelRemovalAccounts(nodeInstalled: true),
      isNot(contains('sky-ui-build')),
    );
    expect(panelRemovalAccounts(nodeInstalled: true), contains('sky-ui'));
    expect(
      panelRemovalAccounts(nodeInstalled: false),
      contains('sky-ui-build'),
    );
  });
}
