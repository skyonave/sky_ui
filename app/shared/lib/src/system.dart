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
