import 'dart:convert';
import 'dart:io';

import 'host.dart';

Future<Map<String, dynamic>> syncCertificates({
  String source = '/var/lib/sky-ui-edge/data/caddy/certificates',
  String destination = '/var/lib/sky-ui-certificates',
  List<String>? hosts,
  String? primary,
  int? sourceUid,
  int? gid,
}) async {
  if (hosts == null) {
    if (!exists('$etc/access.conf')) return {};
    hosts = readText('$etc/access.conf')
        .split('\n')
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    primary = Uri.parse(environment()['SKY_UI_WEB_ORIGIN'] ?? '').host;
  }
  sourceUid ??= (await account('sky-ui-edge')).uid;
  gid ??= (await account('sky-ui')).gid;
  host.mkdir(destination, mode: 0x1e8, gid: gid);
  host.trusted(destination, directory: true);
  var changed = false;
  final index = <String, dynamic>{};
  bool publish(String path, List<int> bytes) {
    if (exists(path) &&
        !isLink(path) &&
        digest(host.read(path, limit: 262144)) == digest(bytes))
      return false;
    host.atomic(path, bytes, gid: gid);
    return true;
  }

  for (final name in hosts) {
    require(
      RegExp(r'^[a-z0-9][a-z0-9.-]{0,252}$').hasMatch(name),
      'certificate_host_invalid',
    );
    final identities = [name, if (name == primary) 'panel'];
    try {
      final prefix =
          '$source/acme-v02.api.letsencrypt.org-directory/$name/$name';
      final chain = host.read('$prefix.crt', limit: 262144, uid: sourceUid),
          key = host.read('$prefix.key', limit: 262144, uid: sourceUid);
      final metadata = await temporary(destination, '.validate-', (work) async {
        host.atomic('$work/cert.pem', chain, mode: 0x180);
        host.atomic('$work/key.pem', key, mode: 0x180);
        final cert = '$work/cert.pem', private = '$work/key.pem';
        await run([
          'openssl',
          'x509',
          '-in',
          cert,
          '-noout',
          '-checkend',
          '60',
        ]);
        await run([
          'openssl',
          'verify',
          '-trusted',
          cert,
          '-partial_chain',
          InternetAddress.tryParse(name) != null
              ? '-verify_ip'
              : '-verify_hostname',
          name,
          cert,
        ]);
        final certPub = await run([
          'openssl',
          'x509',
          '-in',
          cert,
          '-pubkey',
          '-noout',
        ]);
        final keyPub = await run([
          'openssl',
          'pkey',
          '-in',
          private,
          '-passin',
          'pass:',
          '-pubout',
        ]);
        require(certPub.trim() == keyPub.trim(), 'certificate_key_mismatch');
        final expiry = (await run([
          'openssl',
          'x509',
          '-in',
          cert,
          '-noout',
          '-enddate',
        ])).trim().replaceFirst('notAfter=', '');
        final stamp = await run([
          'date',
          '-u',
          '-d',
          expiry,
          '+%Y-%m-%dT%H:%M:%SZ',
        ]);
        final pem = RegExp(
          r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----',
        ).firstMatch(utf8.decode(chain));
        require(pem != null, 'certificate_invalid');
        return {
          'host': name,
          'expiresAt': stamp.trim(),
          'fingerprint': digest(
            base64.decode(pem![1]!.replaceAll(RegExp(r'\s'), '')),
          ),
        };
      });
      for (final id in identities) {
        host.mkdir('$destination/$id', mode: 0x1e8, gid: gid);
        host.trusted('$destination/$id', directory: true);
        changed = publish('$destination/$id/private.key', key) || changed;
        changed = publish('$destination/$id/fullchain.pem', chain) || changed;
        index[id] = metadata;
      }
    } on Object {
      // Preserve the last published pair while ACME storage is transitioning.
      try {
        final old = readJson('$destination/index.json', 262144);
        for (final id in identities)
          if (old.containsKey(id)) index[id] = old[id];
      } on Object {
        /* No previous identity. */
      }
    }
  }
  changed =
      publish(
        '$destination/index.json',
        utf8.encode('${jsonEncode(index)}\n'),
      ) ||
      changed;
  if (changed) stdout.writeln('Updated managed TLS certificate pairs.');
  return index;
}
