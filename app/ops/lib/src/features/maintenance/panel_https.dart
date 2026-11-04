import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../platform/host.dart';
import '../backups/backups.dart';
import 'request.dart';

const httpsIntent = '$state/https-intent.json';
const _files = ['Caddyfile', 'server.env', 'access.conf'];
const _api = 'sky-ui.service', _gateway = 'sky-ui-edge.service';

String httpsEnvironment(String previous, String ip, String domain) {
  return [
    for (final line in const LineSplitter().convert(previous))
      if (!line.startsWith('SKY_UI_WEB_ORIGIN=') &&
          !line.startsWith('SKY_UI_EXTRA_ORIGIN='))
        line,
    'SKY_UI_WEB_ORIGIN=https://${domain.isEmpty ? ip : domain}',
    'SKY_UI_EXTRA_ORIGIN=${domain.isEmpty ? '' : 'https://$ip'}',
    '',
  ].join('\n');
}

Future<void> _checkDns(String domain, String ip) async {
  if (domain.isEmpty) return;
  try {
    final addresses = await InternetAddress.lookup(domain)
        .timeout(const Duration(seconds: 8));
    final ipv4 = addresses.where((a) => a.type == InternetAddressType.IPv4);
    require(
      ipv4.isNotEmpty && ipv4.every((a) => a.address == ip),
      'domain_dns_mismatch',
    );
    final ipv6 = addresses.where((a) => a.type == InternetAddressType.IPv6);
    if (ipv6.isNotEmpty) {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv6,
      );
      final local = interfaces.expand((i) => i.addresses).toSet();
      require(ipv6.every(local.contains), 'domain_dns_mismatch');
    }
  } on SocketException {
    throw const OpsError('domain_dns_missing');
  } on TimeoutException {
    throw const OpsError('domain_dns_missing');
  }
}

void _checkCertificateConsumers(String oldDomain) {
  final db = sqlite3.open('$dataRoot/panel.sqlite', mode: OpenMode.readOnly);
  try {
    for (final row in db.select('SELECT value FROM connections')) {
      final connection = object(jsonDecode(row['value'] as String));
      final settings = object(connection['settings']);
      if (settings['certificateSource'] != 'panel') continue;
      final id = settings['certificateId'] ?? 'panel';
      require(id != 'panel' && id != oldDomain, 'domain_certificate_in_use');
    }
  } finally {
    db.close();
  }
}

Future<void> _probe(
  String hostName, {
  bool checkOrigin = false,
  int seconds = 12,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  do {
    final response = await command(
      [
        'curl',
        '--silent',
        '--noproxy',
        '*',
        '--proto',
        '=https',
        '--connect-timeout',
        '2',
        '--max-time',
        '4',
        '--max-filesize',
        '8192',
        '--resolve',
        '$hostName:443:127.0.0.1',
        if (checkOrigin) ...['--header', 'Origin: https://$hostName'],
        '--write-out',
        '\n%{http_code}',
        'https://$hostName/api/v1/panel',
      ],
      check: false,
      timeout: const Duration(seconds: 6),
    );
    final body = (response.stdout as String).trim();
    if (response.exitCode == 0 && body.endsWith('\n401')) {
      try {
        final payload = jsonDecode(body.substring(0, body.length - 4));
        if (payload is Map &&
            payload['error'] is Map &&
            payload['error']['code'] == 'auth_required')
          return;
      } on FormatException {
        // A foreign route or an unfinished gateway reload can return HTML.
      }
    }
    await sleep(1500);
  } while (DateTime.now().isBefore(deadline));
  throw const OpsError('domain_https_not_ready');
}

Future<void> recoverPanelHttps(int gid, {bool live = false}) async {
  if (!exists(httpsIntent)) return;
  host.trusted(httpsIntent);
  final saved = readJson(httpsIntent, 256 * 1024);
  require(
    saved.length == _files.length && _files.every(saved.containsKey),
    'request_invalid',
  );
  final gateway = await account('sky-ui-edge');
  for (final name in _files) {
    host.atomic(
      '$etc/$name',
      base64.decode(saved[name] as String),
      mode: name == 'access.conf' ? 0x180 : 0x1a0,
      gid: name == 'Caddyfile' ? gateway.gid : gid,
    );
  }
  if (live) {
    await run(['systemctl', 'restart', _api]);
    await apiReady(environment());
    await run(['systemctl', 'reload-or-restart', _gateway]);
    await _probe(
      readText('$etc/access.conf', 4096).split('\n').first,
      checkOrigin: true,
    );
  }
  unlink(httpsIntent);
}

Future<Map<String, dynamic>> changePanelHttps(
  String domain,
  String expectedDomain,
  int gid,
  void Function(String) stage,
) async {
  stage('validate');
  require(
    await active(_api) && await active(_gateway),
    'domain_setup_required',
  );
  for (final name in _files) {
    require(exists('$etc/$name'), 'domain_setup_required');
    host.trusted('$etc/$name');
  }
  final saved = {
    for (final name in _files) name: host.read('$etc/$name', limit: 32768),
  };
  final access = const LineSplitter().convert(
    utf8.decode(saved['access.conf']!),
  );
  final ip = access.firstOrNull ?? '';
  final currentDomain = access.elementAtOrNull(1) ?? '';
  final address = InternetAddress.tryParse(ip);
  require(
    address?.type == InternetAddressType.IPv4 &&
        address!.address == ip &&
        validPanelDomain(currentDomain),
    'domain_setup_required',
  );
  require(currentDomain == expectedDomain, 'domain_state_changed');
  final env = environment();
  require(
    env['SKY_UI_WEB_ORIGIN'] ==
            'https://${currentDomain.isEmpty ? ip : currentDomain}' &&
        env['SKY_UI_GATEWAY_SECRET_FILE'] == '$etc/gateway.secret',
    'domain_setup_required',
  );
  final port = int.tryParse(env['SKY_UI_PORT'] ?? '');
  require(port != null && port >= 1 && port <= 65535, 'domain_setup_required');
  assertConfigurationSettled();
  _checkCertificateConsumers(currentDomain);
  await _checkDns(domain, ip);
  await _probe(ip, checkOrigin: true);
  final gateway = await account('sky-ui-edge');
  return temporary('$state/work', 'tmp', (work) async {
    Future<List<int>> render(String name, [String previous = '']) async {
      final output = '$work/$name';
      await run([
        'bash',
        '$current/deploy/render_access.sh',
        output,
        ip,
        domain,
        '$port',
        '$etc/admin.hash',
        '$etc/gateway.secret',
        previous,
      ]);
      await run(['$current/bin/caddy', 'fmt', '--overwrite', output]);
      await command(
        [
          '$current/bin/caddy',
          'validate',
          '--config',
          output,
          '--adapter',
          'caddyfile',
        ],
        environment: {
          ...cleanEnvironment,
          'XDG_DATA_HOME': work,
          'XDG_CONFIG_HOME': work,
        },
      );
      return host.read(output, limit: 32768);
    }

    final finalConfig = await render('final.Caddyfile');
    final staged = domain.isNotEmpty
        ? await render('staged.Caddyfile', currentDomain)
        : null;
    atomicJson(
      httpsIntent,
      saved.map((k, v) => MapEntry(k, base64.encode(v))),
      mode: 0x180,
    );
    try {
      if (staged != null) {
        stage('certificate');
        host.atomic('$etc/Caddyfile', staged, gid: gateway.gid);
        await run(['systemctl', 'reload', _gateway]);
        await _probe(domain, seconds: 120);
      }
      stage('apply');
      // Stop the API before the last dependency check to drain admitted writes.
      await run(['systemctl', 'stop', _api]);
      assertConfigurationSettled();
      _checkCertificateConsumers(currentDomain);
      host.atomic(
        '$etc/server.env',
        utf8.encode(
          httpsEnvironment(utf8.decode(saved['server.env']!), ip, domain),
        ),
        gid: gid,
      );
      await run(['systemctl', 'start', _api]);
      await apiReady(environment());
      host.atomic('$etc/Caddyfile', finalConfig, gid: gateway.gid);
      await run(['systemctl', 'reload', _gateway]);
      await _probe(ip, checkOrigin: true);
      if (domain.isNotEmpty) await _probe(domain, checkOrigin: true);
      host.atomic(
        '$etc/access.conf',
        utf8.encode('$ip\n$domain\n'),
        mode: 0x180,
      );
      unlink(httpsIntent);
    } on Object {
      try {
        try {
          stage('rollback');
        } on Object {
          // The durable restore does not depend on updating the progress file.
        }
        await recoverPanelHttps(gid, live: true);
      } on Object {
        throw const OpsError('domain_rollback_failed');
      }
      rethrow;
    }
    // Caddy already serves a verified certificate. The timer retries publication.
    try {
      await command([
        'systemctl',
        'start',
        'sky-ui-certificates.service',
      ], check: false);
    } on Object {
      // Leave the independently verified public HTTPS route active.
    }
    return {'address': 'https://${domain.isEmpty ? ip : domain}'};
  });
}
