const coreRepositories = {
  'mihomo': 'MetaCubeX/mihomo',
  'sing-box': 'SagerNet/sing-box',
  'xray': 'XTLS/Xray-core',
};

class SystemSnapshot {
  const SystemSnapshot({
    required this.supported,
    required this.hostname,
    required this.os,
    required this.cpuCores,
    this.cpuPercent,
    this.memoryTotal,
    this.memoryAvailable,
    this.diskTotal,
    this.diskUsed,
    this.uptimeSeconds,
    this.addresses = const [],
    this.rxBytesPerSecond,
    this.txBytesPerSecond,
  });
  final bool supported;
  final String hostname, os;
  final int cpuCores;
  final double? cpuPercent;
  final List<String> addresses;
  final double? rxBytesPerSecond, txBytesPerSecond;
  final int? memoryTotal, memoryAvailable, diskTotal, diskUsed, uptimeSeconds;
  Map<String, Object?> toJson() => {
    'supported': supported,
    'hostname': hostname,
    'os': os,
    'cpuCores': cpuCores,
    'cpuPercent': cpuPercent,
    'memoryTotal': memoryTotal,
    'memoryAvailable': memoryAvailable,
    'diskTotal': diskTotal,
    'diskUsed': diskUsed,
    'uptimeSeconds': uptimeSeconds,
    'addresses': addresses,
    'rxBytesPerSecond': rxBytesPerSecond,
    'txBytesPerSecond': txBytesPerSecond,
  };
  factory SystemSnapshot.fromJson(Map<String, dynamic> j) => SystemSnapshot(
    supported: j['supported'] as bool,
    hostname: j['hostname'] as String,
    os: j['os'] as String,
    cpuCores: j['cpuCores'] as int,
    cpuPercent: (j['cpuPercent'] as num?)?.toDouble(),
    memoryTotal: j['memoryTotal'] as int?,
    memoryAvailable: j['memoryAvailable'] as int?,
    diskTotal: j['diskTotal'] as int?,
    diskUsed: j['diskUsed'] as int?,
    uptimeSeconds: j['uptimeSeconds'] as int?,
    addresses: (j['addresses'] as List? ?? const []).cast<String>(),
    rxBytesPerSecond: (j['rxBytesPerSecond'] as num?)?.toDouble(),
    txBytesPerSecond: (j['txBytesPerSecond'] as num?)?.toDouble(),
  );
}

class CoreRelease {
  const CoreRelease({
    required this.tag,
    required this.name,
    required this.body,
    required this.url,
    required this.date,
  });
  final String tag, name, body, url, date;
  Map<String, Object?> toJson() => {
    'tag': tag,
    'name': name,
    'body': body,
    'url': url,
    'date': date,
  };
  factory CoreRelease.fromJson(Map<String, dynamic> j) => CoreRelease(
    tag: j['tag'] as String,
    name: j['name'] as String,
    body: j['body'] as String,
    url: j['url'] as String,
    date: j['date'] as String,
  );
}

class CoreReleaseNotes {
  const CoreReleaseNotes({
    required this.coreId,
    required this.repository,
    required this.latest,
    required this.releases,
    required this.incomplete,
    this.installed,
  });
  final String coreId, repository, latest;
  final String? installed;
  final bool incomplete;
  final List<CoreRelease> releases;
  Map<String, Object?> toJson() => {
    'coreId': coreId,
    'repository': repository,
    'latest': latest,
    'installed': installed,
    'incomplete': incomplete,
    'releases': releases.map((r) => r.toJson()).toList(),
  };
  factory CoreReleaseNotes.fromJson(Map<String, dynamic> j) => CoreReleaseNotes(
    coreId: j['coreId'] as String,
    repository: j['repository'] as String,
    latest: j['latest'] as String,
    installed: j['installed'] as String?,
    incomplete: j['incomplete'] as bool,
    releases: (j['releases'] as List)
        .map((r) => CoreRelease.fromJson(Map<String, dynamic>.from(r as Map)))
        .toList(),
  );
}
