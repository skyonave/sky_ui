import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../application/access/validation.dart';
import '../../application/contracts/connection_diagnostics.dart';
import '../../shared/api_exception.dart';
import 'socket_owner.dart';

bool publicDiagnosticAddress(InternetAddress address) {
  var b = address.rawAddress;
  if (b.length == 16 &&
      b.take(10).every((v) => v == 0) &&
      b[10] == 255 &&
      b[11] == 255)
    b = b.sublist(12);
  if (b.length == 4) {
    return b[0] != 0 &&
        b[0] != 10 &&
        b[0] != 127 &&
        b[0] < 224 &&
        !(b[0] == 169 && b[1] == 254) &&
        !(b[0] == 172 && b[1] >= 16 && b[1] <= 31) &&
        !(b[0] == 192 &&
            (b[1] == 168 || b[1] == 0 || b[1] == 88 && b[2] == 99)) &&
        !(b[0] == 100 && b[1] >= 64 && b[1] <= 127) &&
        !(b[0] == 198 &&
            (b[1] == 18 || b[1] == 19 || b[1] == 51 && b[2] == 100)) &&
        !(b[0] == 203 && b[1] == 0 && b[2] == 113);
  }
  return b[0] & 0xe0 == 0x20 &&
      !(b[0] == 0x20 &&
          b[1] == 1 &&
          (b[2] == 0x0d && b[3] == 0xb8 || b[2] == 0 && b[3] <= 2));
}

class NativeDiagnosticProbe implements DiagnosticNetworkProbe {
  NativeDiagnosticProbe({
    this.timeout = const Duration(seconds: 5),
    this.opensslExecutable = '/usr/bin/openssl',
    this.trustedCAFile,
    Future<List<InternetAddress>> Function(String)? lookup,
  }) : lookup = lookup ?? InternetAddress.lookup;
  final Duration timeout;
  final String opensslExecutable;
  // Explicit fixture trust only. Production composition uses system roots.
  final String? trustedCAFile;
  final Future<List<InternetAddress>> Function(String) lookup;

  @override
  Future<DiagnosticProbeResult> listener(
    DiagnosticListener listener,
    int? processId,
    DiagnosticCancellation cancellation,
  ) async {
    cancellation.check();
    if (!Platform.isLinux)
      return const DiagnosticProbeResult(
        DiagnosticState.warning,
        'platform_unsupported',
      );
    try {
      if (listener.interfaceName case final String name) {
        if (!RegExp(r'^skyawg[a-f0-9]{8}$').hasMatch(name) ||
            !await Directory('/sys/class/net/$name').exists()) {
          return const DiagnosticProbeResult(
            DiagnosticState.failed,
            'interface_missing',
          );
        }
      }
      if (processId == null || processId <= 0)
        return const DiagnosticProbeResult(
          DiagnosticState.warning,
          'listener_identity_unavailable',
        );
      final uid = await processUid(processId);
      cancellation.check();
      final found = await boundSocketBelongsTo(
        listener.host,
        listener.port,
        uid,
        udp: listener.udp,
      );
      return DiagnosticProbeResult(
        found ? DiagnosticState.passed : DiagnosticState.failed,
        found ? 'listener_ready' : 'listener_missing',
      );
    } on ApiException {
      return const DiagnosticProbeResult(
        DiagnosticState.warning,
        'listener_identity_unavailable',
      );
    } on FileSystemException {
      return const DiagnosticProbeResult(
        DiagnosticState.warning,
        'listener_identity_unavailable',
      );
    }
  }

  @override
  Future<DiagnosticResolution> resolve(
    DiagnosticTlsTarget target,
    DiagnosticCancellation cancellation,
  ) async {
    cancellation.check();
    if (!validAddress(target.host) ||
        !validAddress(target.serverName) ||
        target.port < 1 ||
        target.port > 65535) {
      return const DiagnosticResolution(
        DiagnosticProbeResult(DiagnosticState.failed, 'target_invalid'),
      );
    }
    try {
      final literal = InternetAddress.tryParse(target.host);
      // Local TLS can only use an adapter-projected numeric listener address.
      if (!target.remote && literal == null)
        return const DiagnosticResolution(
          DiagnosticProbeResult(DiagnosticState.failed, 'target_invalid'),
        );
      final addresses = literal == null
          ? await lookup(target.host).timeout(timeout)
          : [literal];
      cancellation.check();
      if (addresses.isEmpty)
        return const DiagnosticResolution(
          DiagnosticProbeResult(DiagnosticState.failed, 'dns_failed'),
        );
      if (target.remote && addresses.any((a) => !publicDiagnosticAddress(a))) {
        return const DiagnosticResolution(
          DiagnosticProbeResult(DiagnosticState.failed, 'target_not_public'),
        );
      }
      final ordered = [...addresses]
        ..sort(
          (a, b) => a.type == b.type
              ? 0
              : a.type == InternetAddressType.IPv4
              ? -1
              : 1,
        );
      final selected = <String>{};
      for (final type in [InternetAddressType.IPv4, InternetAddressType.IPv6]) {
        final first = ordered
            .where((address) => address.type == type)
            .firstOrNull;
        if (first != null) selected.add(first.address);
      }
      for (final address in ordered) {
        if (selected.length < 2) selected.add(address.address);
      }
      return DiagnosticResolution(
        DiagnosticProbeResult(
          DiagnosticState.passed,
          literal == null ? 'dns_ready' : 'address_ready',
          {'addresses': selected.join(', ')},
        ),
        selected.toList(),
      );
    } on TimeoutException {
      return const DiagnosticResolution(
        DiagnosticProbeResult(DiagnosticState.failed, 'dns_timeout'),
      );
    } on SocketException {
      return const DiagnosticResolution(
        DiagnosticProbeResult(DiagnosticState.failed, 'dns_failed'),
      );
    }
  }

  @override
  Future<DiagnosticProbeResult> tcp(
    DiagnosticTlsTarget target,
    List<String> addresses,
    DiagnosticCancellation cancellation,
  ) async {
    var code = 'tcp_failed';
    if (target.port < 1 || target.port > 65535)
      return const DiagnosticProbeResult(
        DiagnosticState.failed,
        'target_invalid',
      );
    for (final address in addresses) {
      cancellation.check();
      // Resolve once and pass the numeric address, preventing DNS rebinding.
      final ip = InternetAddress.tryParse(address);
      if (ip == null || target.remote && !publicDiagnosticAddress(ip))
        return const DiagnosticProbeResult(
          DiagnosticState.failed,
          'target_not_public',
        );
      Socket? socket;
      ConnectionTask<Socket>? task;
      void cancel() {
        task?.cancel();
        socket?.destroy();
      }

      cancellation.add(cancel);
      try {
        task = await Socket.startConnect(ip, target.port);
        if (cancellation.cancelled) cancel();
        socket = await task.socket.timeout(
          timeout,
          onTimeout: () {
            task?.cancel();
            throw TimeoutException('tcp');
          },
        );
        cancellation.check();
        return DiagnosticProbeResult(DiagnosticState.passed, 'tcp_ready', {
          'address': address,
        });
      } on TimeoutException {
        code = 'tcp_timeout';
      } on SocketException catch (e) {
        code = {111, 61, 10061}.contains(e.osError?.errorCode)
            ? 'tcp_refused'
            : 'tcp_failed';
      } finally {
        cancel();
        cancellation.remove(cancel);
      }
    }
    cancellation.check();
    return DiagnosticProbeResult(DiagnosticState.failed, code);
  }

  @override
  Future<DiagnosticProbeResult> tls(
    DiagnosticTlsTarget target,
    String address,
    DiagnosticCancellation cancellation,
  ) async {
    cancellation.check();
    final ip = InternetAddress.tryParse(address);
    if (ip == null ||
        target.port < 1 ||
        target.port > 65535 ||
        !validAddress(target.serverName) ||
        target.remote && !publicDiagnosticAddress(ip)) {
      return const DiagnosticProbeResult(
        DiagnosticState.failed,
        'target_invalid',
      );
    }
    final Process process;
    try {
      process = await Process.start(
        opensslExecutable,
        [
          's_client',
          '-connect',
          '${ip.type == InternetAddressType.IPv6 ? '[$address]' : address}:${target.port}',
          if (InternetAddress.tryParse(target.serverName) == null) ...[
            '-servername',
            target.serverName,
          ] else
            '-noservername',
          InternetAddress.tryParse(target.serverName) == null
              ? '-verify_hostname'
              : '-verify_ip',
          target.serverName,
          '-verify_return_error',
          if (trustedCAFile != null) ...['-CAfile', trustedCAFile!],
          '-brief',
          '-no_ign_eof',
          '-alpn',
          'h2,http/1.1',
          if (target.tls13) '-tls1_3',
        ],
        runInShell: false,
        includeParentEnvironment: false,
        environment: const {
          'PATH': '/usr/bin:/bin',
          'LC_ALL': 'C',
          'LANG': 'C',
        },
      );
    } on ProcessException {
      return const DiagnosticProbeResult(
        DiagnosticState.warning,
        'openssl_missing',
      );
    }
    void cancel() {
      process.kill();
    }

    cancellation.add(cancel);
    final bytes = <int>[];
    void collect(List<int> chunk) {
      final count = 16384 - bytes.length;
      if (count > 0) bytes.addAll(chunk.take(count));
    }

    final output = process.stdout.listen(collect),
        errors = process.stderr.listen(collect);
    final outputDone = output.asFuture<void>(),
        errorsDone = errors.asFuture<void>();
    try {
      // s_client otherwise waits for interactive input after a successful handshake.
      await process.stdin.close();
      final result = await Future.wait<Object?>([
        process.exitCode,
        outputDone,
        errorsDone,
      ]).timeout(timeout);
      cancellation.check();
      return parseTlsProbe(
        result.first as int,
        utf8.decode(bytes, allowMalformed: true),
        requireTls13: target.tls13,
      );
    } on TimeoutException {
      return const DiagnosticProbeResult(DiagnosticState.failed, 'tls_timeout');
    } finally {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        if (!Platform.isWindows) process.kill(ProcessSignal.sigkill);
      }
      cancellation.remove(cancel);
      await output.cancel();
      await errors.cancel();
    }
  }
}

/// Only allowlisted fields leave the process; certificate/session dumps never do.
DiagnosticProbeResult parseTlsProbe(
  int exitCode,
  String output, {
  required bool requireTls13,
}) {
  final verification = RegExp(
    r'verify error:num=(\d+)',
  ).firstMatch(output)?.group(1);
  final protocol = RegExp(
    r'Protocol version:\s*(TLSv[0-9.]+)',
  ).firstMatch(output)?.group(1);
  final cipher = RegExp(
    r'Ciphersuite:\s*([A-Za-z0-9_-]+)',
  ).firstMatch(output)?.group(1);
  if (exitCode == 0 &&
      output.contains('Verification: OK') &&
      protocol != null &&
      (!requireTls13 || protocol == 'TLSv1.3')) {
    return DiagnosticProbeResult(DiagnosticState.passed, 'tls_ready', {
      'protocol': protocol,
      if (cipher != null) 'cipher': cipher,
    });
  }
  final code = switch (verification) {
    '62' || '64' => 'tls_name_mismatch',
    '9' => 'tls_not_yet_valid',
    '10' => 'tls_expired',
    '18' || '19' || '20' || '21' => 'tls_untrusted',
    _ =>
      output.contains('protocol version') ||
              requireTls13 && protocol != null && protocol != 'TLSv1.3'
          ? 'tls_version'
          : 'tls_failed',
  };
  return DiagnosticProbeResult(DiagnosticState.failed, code);
}
