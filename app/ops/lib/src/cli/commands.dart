import 'dart:io';

import '../platform/host.dart';
import 'certificates.dart';
import 'context.dart';
import 'lifecycle.dart';
import 'maintenance.dart';
import 'uninstall.dart';

export 'certificates.dart';
export 'context.dart';
export 'lifecycle.dart';
export 'maintenance.dart';
export 'uninstall.dart';

Future<void> cliMain(List<String> args) async {
  if (args.isEmpty || ['--help', '-h'].contains(args.first)) {
    stdout.writeln(
      'Sky UI: status, version, setup, start|stop|restart [panel|core|all|sing-box|xray|amneziawg],\nlogs [target] [-f] [-n 100], certificates [status|setup|check|logs],\nbackup, backups, restore ID, install-core|update-core|remove-core [engine], update, cleanup, uninstall',
    );
    return;
  }
  managed();
  final action = args.first;
  if ([
    'backup',
    'backups',
    'restore',
    'install-core',
    'update-core',
    'remove-core',
    'update',
  ].contains(action))
    return maintenanceCli(args);
  if (['start', 'stop', 'restart'].contains(action)) {
    require(args.length <= 2, 'request_invalid');
    return lifecycle(action, args.length == 2 ? args[1] : 'panel');
  }
  switch (action) {
    case 'version':
      stdout.writeln(panelVersion());
    case 'status':
      await status();
    case 'setup':
      await interactive(['bash', '$current/deploy/setup.sh', 'setup']);
    case 'cleanup':
      await run(['systemctl', 'start', 'sky-ui-cleanup.service']);
      stdout.writeln(
        'Свободно: ${((await freeBytes(state)) / 1073741824).toStringAsFixed(1)} GB',
      );
    case 'uninstall':
      await uninstall();
    case 'logs':
    case 'certificates':
      var target = action == 'logs' ? 'panel' : 'status',
          follow = false,
          lines = 100;
      for (var i = 1; i < args.length; i++) {
        final a = args[i];
        if (a == '-f' || a == '--follow')
          follow = true;
        else if (a == '-n' || a == '--lines') {
          require(i + 1 < args.length, 'request_invalid');
          lines = int.parse(args[++i]);
        } else {
          require(i == 1, 'request_invalid');
          target = a;
        }
      }
      require(lines >= 1 && lines <= 10000, 'request_invalid');
      if (action == 'logs')
        await logs(target, follow: follow, lines: lines);
      else
        await certificates(target, follow: follow, lines: lines);
    default:
      throw const OpsError('request_invalid');
  }
}
