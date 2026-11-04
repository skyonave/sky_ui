class PanelHttpsStatus {
  const PanelHttpsStatus({
    required this.available,
    required this.ip,
    required this.domain,
    required this.expiresAt,
  });

  final bool available;
  final String ip, domain;
  final Map<String, String> expiresAt;

  factory PanelHttpsStatus.fromJson(Map<String, dynamic> json) =>
      PanelHttpsStatus(
        available: json['available'] as bool,
        ip: json['ip'] as String,
        domain: json['domain'] as String,
        expiresAt: Map<String, String>.from(json['expiresAt'] as Map),
      );

  Map<String, Object?> toJson() => {
    'available': available,
    'ip': ip,
    'domain': domain,
    'expiresAt': expiresAt,
  };
}

bool validPanelDomain(String value) =>
    value.isEmpty ||
    value.length <= 253 &&
        RegExp(r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$')
            .hasMatch(value);
