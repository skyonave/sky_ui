import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import '../../application/access/records.dart';
import '../../shared/api_exception.dart';

bool publicSniAddress(InternetAddress address) {
  if (address.type != InternetAddressType.IPv4) return false;
  final b = address.rawAddress;
  return b[0] != 0 &&
      b[0] != 10 &&
      b[0] != 127 &&
      b[0] < 224 &&
      !(b[0] == 169 && b[1] == 254) &&
      !(b[0] == 172 && b[1] >= 16 && b[1] <= 31) &&
      !(b[0] == 192 && b[1] == 168) &&
      !(b[0] == 100 && b[1] >= 64 && b[1] <= 127) &&
      !(b[0] == 198 && [18, 19].contains(b[1]));
}

List<String> neighboringSniAddresses(InternetAddress address) {
  if (!publicSniAddress(address))
    throw const ApiException('sni_address_invalid', status: 422);
  final b = address.rawAddress, host = b[3], result = <String>[];
  for (var distance = 1; distance <= 64 && result.length < 64; distance++) {
    for (final last in [host - distance, host + distance]) {
      if (last > 0 && last < 255 && result.length < 64)
        result.add('${b[0]}.${b[1]}.${b[2]}.$last');
    }
  }
  return result;
}

List<String> sniCsvRow(String line) {
  final fields = <String>[], value = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') {
      if (quoted && i + 1 < line.length && line[i + 1] == '"') {
        value.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (c == ',' && !quoted) {
      fields.add(value.toString());
      value.clear();
    } else {
      value.write(c);
    }
  }
  if (quoted) return [];
  fields.add(value.toString());
  return fields;
}

/// One bounded, unprivileged job. No arbitrary CIDR, URL, executable or file input.
class SniScanner {
  SniScanner({
    this.binary = '/opt/sky-ui/tools/realitlscanner/current/realitlscanner',
  });
  final String binary;
  bool get supported => Platform.isLinux && Abi.current() == Abi.linuxX64;
  bool get installed => supported && File(binary).existsSync();
  bool _working = false, _cancelled = false;
  final _processes = <Process>{};
  Map<String, dynamic> _job = {'status': 'idle', 'results': <Object>[]};
  Map<String, dynamic> get snapshot => {
    ..._job,
    'supported': supported,
    'installed': installed,
  };

  Map<String, dynamic> start(String address) {
    if (!supported)
      throw const ApiException('sni_tool_platform_unsupported', status: 422);
    if (!installed) throw const ApiException('sni_tool_missing', status: 409);
    if (_working) throw const ApiException('sni_scan_busy', status: 409);
    _working = true;
    _cancelled = false;
    _job = {
      'id': secureToken(16),
      'status': 'running',
      'stage': 'resolve',
      'completed': 0,
      'total': 0,
      'results': <Map<String, Object?>>[],
    };
    unawaited(_scan(address));
    return snapshot;
  }

  void cancel(String id) {
    if (_job['id'] != id) throw const ApiException('not_found', status: 404);
    if (!_working) return;
    _cancelled = true;
    _job['stage'] = 'cancelling';
    for (final process in _processes) {
      process.kill();
    }
  }

  Future<void> _scan(String address) async {
    Directory? work;
    var aborted = false;
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    void check() {
      if (_cancelled) throw const ApiException('sni_scan_cancelled');
      if (aborted) throw const ApiException('sni_scan_failed');
    }

    try {
      final resolved = await InternetAddress.lookup(
        address,
        type: InternetAddressType.IPv4,
      ).timeout(const Duration(seconds: 4));
      check();
      if (resolved.isEmpty || resolved.any((a) => !publicSniAddress(a)))
        throw const ApiException('sni_address_invalid', status: 422);
      final targets = neighboringSniAddresses(resolved.first),
          seen = <String>{};
      _job.addAll({'stage': 'scan', 'total': targets.length});
      final directory = await Directory.systemTemp.createTemp('sky-ui-sni-');
      work = directory;
      Future<void> probe(int index) async {
        check();
        final target = targets[index],
            input = File('${directory.path}/$index-in.txt'),
            output = File('${directory.path}/$index-out.csv');
        await input.writeAsString('$target\n');
        // -in is finite; the tool's single-IP -addr mode scans indefinitely.
        // Isolate each target: v0.2.2 can panic on certificates without DNS SANs.
        final process = await Process.start(
          binary,
          [
            '-in',
            input.path,
            '-out',
            output.path,
            '-port',
            '443',
            '-thread',
            '1',
            '-timeout',
            '2',
          ],
          workingDirectory: directory.path,
          environment: {'PATH': '/usr/bin:/bin'},
          includeParentEnvironment: false,
        );
        _processes.add(process);
        final stdoutDone = process.stdout.drain<void>(),
            stderrDone = process.stderr.drain<void>();
        int code;
        try {
          code = await process.exitCode.timeout(const Duration(seconds: 8));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode;
          code = -1;
        }
        await Future.wait([stdoutDone, stderrDone]);
        _processes.remove(process);
        check();
        if (code != 0) {
          _job['exitCode'] = code;
          _job['skipped'] = (_job['skipped'] as int? ?? 0) + 1;
          return;
        }
        if (await output.exists()) {
          if (await output.length() > 262144)
            throw const ApiException('sni_scan_failed');
          final rows = const LineSplitter().convert(
            await output.readAsString(),
          );
          final headers = rows.isEmpty ? <String>[] : sniCsvRow(rows.first);
          for (final line in rows.skip(1)) {
            check();
            final row = sniCsvRow(line);
            String column(String name) {
              final index = headers.indexOf(name);
              return index >= 0 && index < row.length ? row[index] : '';
            }

            final ip = column('IP'),
                domain = column('CERT_DOMAIN').toLowerCase(),
                curve = column('CURVE');
            if (ip != target ||
                !RegExp(
                  r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
                ).hasMatch(domain) ||
                !column('TLS').contains('1.3') ||
                column('ALPN') != 'h2' ||
                !curve.contains('X25519') ||
                !seen.add(domain))
              continue;
            final result = await _verify(ip, domain, curve);
            if (result != null) {
              final results = _job['results'] as List;
              results.add(result);
              results.sort(
                (a, b) =>
                    (a['latencyMs'] as int).compareTo(b['latencyMs'] as int),
              );
            }
          }
        }
      }

      var cursor = 0;
      Future<void> worker() async {
        try {
          while (cursor < targets.length && DateTime.now().isBefore(deadline)) {
            check();
            final index = cursor++;
            await probe(index);
            _job['completed'] = (_job['completed'] as int) + 1;
          }
        } on Object {
          aborted = true;
          rethrow;
        }
      }

      await Future.wait([worker(), worker()]);
      check();
      if (_job['skipped'] == targets.length)
        throw const ApiException('sni_scan_failed');
      _job['status'] = 'completed';
      _job['stage'] = 'complete';
      _job['partial'] = _job['completed'] != targets.length;
    } on Object catch (error) {
      _job['status'] = _cancelled ? 'cancelled' : 'failed';
      _job['error'] = error is ApiException
          ? error.code
          : error is TimeoutException
          ? 'sni_scan_timeout'
          : 'sni_scan_failed';
      _job['errorType'] = '${error.runtimeType}';
      if (error is ProcessException) _job['osErrorCode'] = error.errorCode;
      if (error is FileSystemException)
        _job['osErrorCode'] = error.osError?.errorCode;
    } finally {
      for (final process in _processes.toList()) {
        process.kill();
        try {
          await process.exitCode.timeout(const Duration(seconds: 1));
        } on TimeoutException {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode;
        }
      }
      _processes.clear();
      try {
        if (work != null && await work.exists())
          await work.delete(recursive: true);
      } on FileSystemException {
        _job['error'] ??= 'sni_cleanup_failed';
      } finally {
        _working = false;
      }
    }
  }

  Future<Map<String, Object?>?> _verify(
    String ip,
    String domain,
    String curve,
  ) async {
    Socket? raw;
    SecureSocket? tls;
    final watch = Stopwatch()..start();
    try {
      final addresses = await InternetAddress.lookup(
        domain,
        type: InternetAddressType.IPv4,
      ).timeout(const Duration(seconds: 2));
      if (addresses.any((a) => !publicSniAddress(a)) ||
          !addresses.any((a) => a.address == ip))
        return null;
      raw = await Socket.connect(
        InternetAddress(ip),
        443,
        timeout: const Duration(seconds: 2),
      );
      // Unlike the discovery tool, validate the certificate and concrete SNI.
      tls = await SecureSocket.secure(
        raw,
        host: domain,
        supportedProtocols: ['h2'],
      ).timeout(const Duration(seconds: 2));
      if (tls.selectedProtocol != 'h2') return null;
      return {
        'domain': domain,
        'ip': ip,
        'tls': '1.3',
        'alpn': 'h2',
        'curve': curve,
        'latencyMs': watch.elapsedMilliseconds,
      };
    } on Object {
      return null;
    } finally {
      tls?.destroy();
      raw?.destroy();
    }
  }
}
