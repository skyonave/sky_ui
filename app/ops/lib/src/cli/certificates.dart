import 'dart:io';

import '../platform/host.dart';
import 'context.dart';
import 'lifecycle.dart';

Future<void> certificates(
  String action, {
  bool follow = false,
  int lines = 100,
}) async {
  require(
    ['status', 'setup', 'check', 'logs'].contains(action),
    'request_invalid',
  );
  if (action == 'setup')
    return interactive(['bash', '$current/deploy/setup.sh', 'setup']);
  if (action == 'logs')
    return logs('certificates', follow: follow, lines: lines);
  if (action == 'check') {
    await locked(() async {
      require(
        !exists('$state/https-intent.json'),
        'maintenance_recovery_required',
      );
      await run(['systemctl', 'reload', 'sky-ui-edge.service']);
      await run(['systemctl', 'start', 'sky-ui-certificates.service']);
    });
    stdout.writeln(
      'Настройки HTTPS применены, сертификаты синхронизированы с ядрами.',
    );
  }
  final access = exists('$etc/access.conf')
      ? readText('$etc/access.conf', 4096).split('\n')
      : <String>[];
  stdout.writeln('IP: ${access.isEmpty ? '—' : access.first}');
  stdout.writeln(
    'Домен: ${access.length > 1 && access[1].isNotEmpty ? access[1] : 'не настроен'}',
  );
  const root = '/var/lib/sky-ui-edge/data/caddy/certificates';
  var found = false;
  if (exists(root))
    for (final cert
        in Directory(root)
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((f) => f.path.endsWith('.crt'))) {
      found = true;
      stdout.writeln(basename(parent(cert.path)));
      await interactive([
        'openssl',
        'x509',
        '-in',
        cert.path,
        '-noout',
        '-subject',
        '-issuer',
        '-dates',
      ]);
    }
  if (!found)
    stdout.writeln('Выпущенных сертификатов пока нет. Проверь логи HTTPS.');
  stdout.writeln('Продлением управляет Caddy автоматически.');
  await interactive([
    'systemctl',
    'list-timers',
    'sky-ui-certificates.timer',
    '--no-pager',
  ]);
}
