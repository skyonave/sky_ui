import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_shared/sky_ui_shared.dart';

class PanelHttps {
  PanelHttps({
    required this.origin,
    required this.additionalOrigins,
    required this.certificatesDirectory,
    required this.enabled,
  });

  final Uri origin;
  final List<Uri> additionalOrigins;
  final String certificatesDirectory;
  final bool enabled;

  static bool _ipv4(String host) =>
      InternetAddress.tryParse(host)?.type == InternetAddressType.IPv4;

  String get ip =>
      [origin, ...additionalOrigins]
          .where(
            (url) =>
                url.scheme == 'https' && url.port == 443 && _ipv4(url.host),
          )
          .firstOrNull
          ?.host ??
      '';

  String get domain =>
      origin.scheme == 'https' && !_ipv4(origin.host) ? origin.host : '';

  bool get available =>
      enabled &&
      origin.port == 443 &&
      ip.isNotEmpty &&
      validPanelDomain(domain);

  Future<PanelHttpsStatus> snapshot() async {
    final expiresAt = <String, String>{};
    try {
      final file = File('$certificatesDirectory/index.json');
      if (await file.length() <= 262144) {
        final index = jsonDecode(await file.readAsString()) as Map;
        for (final name in [ip, domain].where((v) => v.isNotEmpty)) {
          final entry = index[name];
          if (entry is! Map || entry['host'] != name) continue;
          final expires = DateTime.tryParse(
            entry['expiresAt']?.toString() ?? '',
          );
          if (expires != null)
            expiresAt[name] = expires.toUtc().toIso8601String();
        }
      }
    } on Object {
      // Metadata may be absent while Caddy is issuing its first certificate.
    }
    return PanelHttpsStatus(
      available: available,
      ip: ip,
      domain: domain,
      expiresAt: expiresAt,
    );
  }
}
