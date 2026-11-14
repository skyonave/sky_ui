import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Read-only network probes run on the managed node, never on the panel host.
Future<Map<String, Object?>> probeNodeNetwork(
  Map<String, dynamic> request, {
  Set<int> localTcpPorts = const {},
}) async {
  final cancellation = NodeProbeCancellation();
  final signals = <StreamSubscription<ProcessSignal>>[];
  if (!Platform.isWindows) {
    for (final signal in [
      ProcessSignal.sigterm,
      ProcessSignal.sigint,
      ProcessSignal.sighup,
    ]) {
      signals.add(signal.watch().listen((_) => cancellation.cancel()));
    }
  }
  try {
    return await NodeDiagnosticProbe().run(
      request,
      localTcpPorts: localTcpPorts,
      cancellation: cancellation,
    );
  } finally {
    cancellation.cancel();
    for (final signal in signals) {
      await signal.cancel();
    }
  }
}

class NodeProbeCancellation {
  final _done = Completer<void>();
  final _callbacks = <void Function()>{};
  bool get cancelled => _done.isCompleted;
  void check() {
    if (cancelled) throw const _Cancelled();
  }

  void add(void Function() callback) {
    if (cancelled) {
      callback();
    } else {
      _callbacks.add(callback);
    }
  }

  void remove(void Function() callback) => _callbacks.remove(callback);
  void cancel() {
    if (cancelled) return;
    _done.complete();
    for (final callback in [..._callbacks]) {
      callback();
    }
    _callbacks.clear();
  }

  Future<T> wait<T>(Future<T> value) => Future.any([
    value,
    _done.future.then<T>((_) => throw const _Cancelled()),
  ]);
}

class _Cancelled implements Exception {
  const _Cancelled();
}

Map<String, Object?> _result(
  String state,
  String code, [
  Map<String, String> details = const {},
]) => {'state': state, 'code': code, 'details': details};

bool _validName(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 253 ||
      value.contains('%'))
    return false;
  if (InternetAddress.tryParse(value) != null) return true;
  return value
      .split('.')
      .every(
        (part) =>
            part.isNotEmpty &&
            part.length <= 63 &&
            RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$')
                .hasMatch(part),
      );
}

List<int> _addressBytes(InternetAddress address) {
  final bytes = address.rawAddress;
  if (bytes.length == 16 &&
      bytes.take(10).every((v) => v == 0) &&
      bytes[10] == 255 &&
      bytes[11] == 255) {
    return bytes.sublist(12);
  }
  return bytes;
}

bool publicNodeProbeAddress(InternetAddress address) {
  final b = _addressBytes(address);
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

bool _loopback(InternetAddress address) {
  final bytes = _addressBytes(address);
  return bytes.length == 4 ? bytes[0] == 127 : address.isLoopback;
}

class NodeDiagnosticProbe {
  NodeDiagnosticProbe({
    this.timeout = const Duration(seconds: 5),
    this.opensslExecutable = '/usr/bin/openssl',
    this.trustedCAFile,
    Future<List<InternetAddress>> Function(String)? lookup,
    Future<Process> Function(List<String>)? startTls,
  }) : lookup = lookup ?? InternetAddress.lookup,
       _startTls = startTls;

  final Duration timeout;
  final String opensslExecutable;
  // Tests can trust an isolated CA; the SSH request cannot override trust/tools.
  final String? trustedCAFile;
  final Future<List<InternetAddress>> Function(String) lookup;
  final Future<Process> Function(List<String>)? _startTls;

  Future<Map<String, Object?>> run(
    Map<String, dynamic> request, {
    Set<int> localTcpPorts = const {},
    NodeProbeCancellation? cancellation,
  }) async {
    final cancel = cancellation ?? NodeProbeCancellation();
    const keys = {
      'stage',
      'host',
      'port',
      'serverName',
      'remote',
      'tls13',
      'addresses',
    };
    final stage = request['stage'];
    final port = request['port'];
    final remote = request['remote'];
    final addresses = request['addresses'];
    if (request.keys.any((k) => !keys.contains(k)) ||
        !const {'dns', 'tcp', 'tls'}.contains(stage) ||
        !_validName(request['host']) ||
        !_validName(request['serverName']) ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        remote is! bool ||
        request['tls13'] is! bool ||
        addresses is! List ||
        addresses.length > 2 ||
        addresses.any((v) => v is! String || v.length > 64) ||
        stage == 'dns' && addresses.isNotEmpty ||
        stage == 'tcp' && addresses.isEmpty ||
        stage == 'tls' && addresses.length != 1) {
      return _result('failed', 'target_invalid');
    }
    final host = request['host'] as String;
    final literal = InternetAddress.tryParse(host);
    if (!remote &&
        (literal == null ||
            !_loopback(literal) ||
            !localTcpPorts.contains(port))) {
      return _result('failed', 'target_invalid');
    }
    if (remote && literal != null && !publicNodeProbeAddress(literal)) {
      return _result('failed', 'target_not_public');
    }
    final ips = <InternetAddress>[];
    for (final value in addresses) {
      final ip = InternetAddress.tryParse(value as String);
      if (ip == null) return _result('failed', 'target_invalid');
      if (remote ? !publicNodeProbeAddress(ip) : !_loopback(ip)) {
        return _result(
          'failed',
          remote ? 'target_not_public' : 'target_invalid',
        );
      }
      ips.add(ip);
    }
    try {
      cancel.check();
      if (stage == 'dns') return await _resolve(host, literal, remote, cancel);
      if (stage == 'tcp') return await _tcp(ips, port, cancel);
      return await _tls(
        ips.single,
        port,
        request['serverName'] as String,
        request['tls13'] as bool,
        cancel,
      );
    } on _Cancelled {
      return _result('warning', 'check_failed');
    }
  }

  Future<Map<String, Object?>> _resolve(
    String host,
    InternetAddress? literal,
    bool remote,
    NodeProbeCancellation cancellation,
  ) async {
    try {
      final addresses = literal == null
          ? await cancellation.wait(lookup(host).timeout(timeout))
          : [literal];
      cancellation.check();
      if (addresses.isEmpty) return _result('failed', 'dns_failed');
      if (remote && addresses.any((ip) => !publicNodeProbeAddress(ip))) {
        return _result('failed', 'target_not_public');
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
        final first = ordered.where((ip) => ip.type == type).firstOrNull;
        if (first != null) selected.add(first.address);
      }
      for (final ip in ordered) {
        if (selected.length < 2) selected.add(ip.address);
      }
      return {
        ..._result('passed', literal == null ? 'dns_ready' : 'address_ready', {
          'addresses': selected.join(', '),
        }),
        'addresses': selected.toList(),
      };
    } on TimeoutException {
      return _result('failed', 'dns_timeout');
    } on SocketException {
      return _result('failed', 'dns_failed');
    }
  }

  Future<Map<String, Object?>> _tcp(
    List<InternetAddress> addresses,
    int port,
    NodeProbeCancellation cancellation,
  ) async {
    var code = 'tcp_failed';
    final elapsed = Stopwatch()..start();
    for (final ip in addresses) {
      cancellation.check();
      final remaining = timeout - elapsed.elapsed;
      if (remaining <= Duration.zero) return _result('failed', 'tcp_timeout');
      ConnectionTask<Socket>? task;
      Socket? socket;
      void close() {
        task?.cancel();
        socket?.destroy();
      }

      cancellation.add(close);
      try {
        task = await Socket.startConnect(ip, port);
        if (cancellation.cancelled) close();
        socket = await cancellation.wait(task.socket.timeout(remaining));
        cancellation.check();
        return _result('passed', 'tcp_ready', {'address': ip.address});
      } on TimeoutException {
        code = 'tcp_timeout';
      } on SocketException catch (error) {
        code = {111, 61, 10061}.contains(error.osError?.errorCode)
            ? 'tcp_refused'
            : 'tcp_failed';
      } finally {
        close();
        cancellation.remove(close);
      }
    }
    cancellation.check();
    return _result('failed', code);
  }

  Future<Map<String, Object?>> _tls(
    InternetAddress ip,
    int port,
    String serverName,
    bool tls13,
    NodeProbeCancellation cancellation,
  ) async {
    final arguments = [
      's_client',
      '-connect',
      '${ip.type == InternetAddressType.IPv6 ? '[${ip.address}]' : ip.address}:$port',
      if (InternetAddress.tryParse(serverName) == null) ...[
        '-servername',
        serverName,
      ] else
        '-noservername',
      InternetAddress.tryParse(serverName) == null
          ? '-verify_hostname'
          : '-verify_ip',
      serverName,
      '-verify_return_error',
      if (trustedCAFile != null) ...['-CAfile', trustedCAFile!],
      '-brief',
      '-no_ign_eof',
      '-alpn',
      'h2,http/1.1',
      if (tls13) '-tls1_3',
    ];
    final Process process;
    try {
      process =
          await (_startTls?.call(arguments) ??
              Process.start(
                opensslExecutable,
                arguments,
                runInShell: false,
                includeParentEnvironment: false,
                environment: const {
                  'PATH': '/usr/bin:/bin',
                  'LANG': 'C',
                  'LC_ALL': 'C',
                },
              ));
    } on ProcessException {
      return _result('warning', 'openssl_missing');
    }
    void stop() => process.kill();
    cancellation.add(stop);
    final bytes = <int>[];
    void collect(List<int> chunk) {
      if (bytes.length < 16384) bytes.addAll(chunk.take(16384 - bytes.length));
    }

    final output = process.stdout.listen(collect),
        errors = process.stderr.listen(collect);
    final done = Future.wait<Object?>([
      process.exitCode,
      output.asFuture<void>(),
      errors.asFuture<void>(),
    ]);
    try {
      await process.stdin.close();
      final result = await cancellation.wait(done.timeout(timeout));
      cancellation.check();
      return parseNodeTlsProbe(
        result.first as int,
        utf8.decode(bytes, allowMalformed: true),
        requireTls13: tls13,
      );
    } on TimeoutException {
      return _result('failed', 'tls_timeout');
    } on IOException {
      return _result('failed', 'tls_failed');
    } finally {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        if (!Platform.isWindows) process.kill(ProcessSignal.sigkill);
        try {
          await process.exitCode.timeout(const Duration(seconds: 1));
        } on TimeoutException {
          // A stuck kernel task must not hold the diagnostic request open.
        }
      }
      cancellation.remove(stop);
      await output.cancel();
      await errors.cancel();
    }
  }
}

/// Keep certificate/session dumps out of both the API response and panel logs.
Map<String, Object?> parseNodeTlsProbe(
  int exitCode,
  String output, {
  required bool requireTls13,
}) {
  final verification = RegExp(r'verify error:num=(\d+)')
      .firstMatch(output)
      ?.group(1);
  final protocol = RegExp(r'Protocol version:\s*(TLSv[0-9.]+)')
      .firstMatch(output)
      ?.group(1);
  final cipher = RegExp(r'Ciphersuite:\s*([A-Za-z0-9_-]+)')
      .firstMatch(output)
      ?.group(1);
  if (exitCode == 0 &&
      output.contains('Verification: OK') &&
      protocol != null &&
      (!requireTls13 || protocol == 'TLSv1.3')) {
    return _result('passed', 'tls_ready', {
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
  return _result('failed', code);
}
