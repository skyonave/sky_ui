import 'dart:io';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'process_runner.dart';

class SystemMonitor {
  SystemMonitor(
    this.dataDirectory, {
    this.runner = const NativeCommandRunner(),
  });
  final String dataDirectory;
  final CommandRunner runner;
  int? _total, _idle;
  final _clock = Stopwatch()..start();
  int? _networkTime, _rx, _tx;
  String? _networkInterfaces;
  Future<SystemSnapshot> snapshot() async {
    final hostname = Platform.localHostname;
    final os = Platform.operatingSystem;
    final cores = Platform.numberOfProcessors;
    final addresses = <String>[];
    final interfaceNames = <String>{};
    try {
      for (final network in await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
      )) {
        interfaceNames.add(network.name);
        for (final address in network.addresses) {
          if (!address.isLoopback && !address.isLinkLocal)
            addresses.add(address.address);
        }
      }
      addresses.sort(
        (a, b) => a.contains(':') == b.contains(':')
            ? a.compareTo(b)
            : a.contains(':')
            ? 1
            : -1,
      );
    } on Object {}
    if (!Platform.isLinux)
      return SystemSnapshot(
        supported: false,
        hostname: hostname,
        os: os,
        cpuCores: cores,
        addresses: addresses,
      );
    double? cpu;
    double? rxRate, txRate;
    int? memoryTotal, memoryAvailable, diskTotal, diskUsed, uptime;
    try {
      final stat = await File('/proc/stat').readAsLines();
      final parts = stat.first
          .trim()
          .split(RegExp(r'\s+'))
          .skip(1)
          .take(8)
          .map(int.parse)
          .toList();
      final total = parts.fold<int>(0, (a, b) => a + b),
          idle = parts[3] + parts[4];
      if (_total != null && total > _total!)
        cpu = ((1 - (idle - _idle!) / (total - _total!)) * 100)
            .clamp(0, 100)
            .toDouble();
      _total = total;
      _idle = idle;
      final memory = <String, int>{};
      for (final line in await File('/proc/meminfo').readAsLines()) {
        final pair = line.split(':');
        memory[pair[0]] =
            int.parse(pair[1].trim().split(RegExp(r'\s+')).first) * 1024;
      }
      memoryTotal = memory['MemTotal'];
      memoryAvailable = memory['MemAvailable'];
      uptime = double.parse(
        (await File('/proc/uptime').readAsString()).split(' ').first,
      ).floor();
    } on Object {
      /* Report missing measurements without inventing values. */
    }
    try {
      final routes = (await File('/proc/net/route').readAsLines())
          .skip(1)
          .map((line) => line.trim().split(RegExp(r'\s+')))
          .where(
            (p) =>
                p.length > 6 &&
                p[1] == '00000000' &&
                (int.parse(p[3], radix: 16) & 1) != 0,
          )
          .toList();
      if (routes.isNotEmpty) {
        routes.sort((a, b) => int.parse(a[6]).compareTo(int.parse(b[6])));
        final metric = routes.first[6];
        interfaceNames
          ..clear()
          ..addAll(routes.where((r) => r[6] == metric).map((r) => r[0]));
      }
      var rx = 0, tx = 0;
      for (final line in (await File('/proc/net/dev').readAsLines()).skip(2)) {
        final split = line.split(':');
        if (split.length != 2 || !interfaceNames.contains(split[0].trim()))
          continue;
        final counters = split[1].trim().split(RegExp(r'\s+'));
        rx += int.parse(counters[0]);
        tx += int.parse(counters[8]);
      }
      final signature = (interfaceNames.toList()..sort()).join(','),
          now = _clock.elapsedMicroseconds;
      if (_networkTime != null &&
          signature == _networkInterfaces &&
          now > _networkTime!) {
        final seconds = (now - _networkTime!) / 1000000;
        rxRate = ((rx - _rx!).clamp(0, 1 << 62)) / seconds;
        txRate = ((tx - _tx!).clamp(0, 1 << 62)) / seconds;
      }
      _networkInterfaces = signature;
      _networkTime = now;
      _rx = rx;
      _tx = tx;
    } on Object {
      /* Network counters may be absent in restricted hosts. */
    }
    try {
      final result = await runner.run('/usr/bin/df', [
        '-B1',
        '--output=size,used',
        '--',
        dataDirectory,
      ], timeout: const Duration(seconds: 2));
      if (result.exitCode == 0) {
        final parts = result.output
            .trim()
            .split('\n')
            .last
            .trim()
            .split(RegExp(r'\s+'));
        diskTotal = int.parse(parts[0]);
        diskUsed = int.parse(parts[1]);
      }
    } on Object {
      /* Other metrics remain usable if disk probing fails. */
    }
    return SystemSnapshot(
      supported: true,
      hostname: hostname,
      os: os,
      cpuCores: cores,
      cpuPercent: cpu,
      memoryTotal: memoryTotal,
      memoryAvailable: memoryAvailable,
      diskTotal: diskTotal,
      diskUsed: diskUsed,
      uptimeSeconds: uptime,
      addresses: addresses,
      rxBytesPerSecond: rxRate,
      txBytesPerSecond: txRate,
    );
  }
}
