import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../application/contracts/connection_diagnostics.dart';
import '../../shared/api_exception.dart';
import '../process/ssh_servers.dart';

/// Only typed observations cross the privileged node boundary.
class SshConnectionDiagnostics implements RemoteConnectionDiagnostics {
  const SshConnectionDiagnostics(this.servers);
  final SshServers servers;

  @override
  Future<RemoteDiagnosticSnapshot> inspect(
    String node,
    String core,
    DiagnosticCancellation cancellation,
  ) async {
    cancellation.check();
    final data = await servers.diagnose(
      node,
      core,
      cancellation: cancellation.whenCancelled,
    );
    cancellation.check();
    final installed = data['installed'] == true;
    return RemoteDiagnosticSnapshot(
      installed: installed,
      state: '${data['state']}',
      hash: '${data['hash']}',
      version: data['version'] as String? ?? '',
      processId: data['pid'] as int?,
      native: !installed
          ? const DiagnosticProbeResult(
              DiagnosticState.skipped,
              'binary_missing',
            )
          : DiagnosticProbeResult(
              data['nativeValid'] == true
                  ? DiagnosticState.passed
                  : DiagnosticState.failed,
              data['nativeValid'] == true
                  ? 'native_ready'
                  : const {
                      'validator_missing',
                      'validator_timeout',
                    }.contains(data['nativeCode'])
                  ? data['nativeCode'] as String
                  : 'native_invalid',
            ),
      listeners: [
        for (final item in data['listeners'] as List? ?? const [])
          if (item is Map &&
              item['port'] is int &&
              item['host'] is String &&
              item['udp'] is bool)
            DiagnosticListener(
              host: item['host'] as String,
              port: item['port'] as int,
              udp: item['udp'] as bool,
              interfaceName: item['interface'] as String?,
            ),
      ],
    );
  }

  @override
  DiagnosticNetworkProbe probe(String node, String core) =>
      _SshProbe(servers, node, core);
}

class _SshProbe implements DiagnosticNetworkProbe {
  const _SshProbe(this.servers, this.node, this.core);
  final SshServers servers;
  final String node, core;

  Future<Map<String, dynamic>> _request(
    String stage,
    DiagnosticTlsTarget target,
    List<String> addresses,
    DiagnosticCancellation cancellation,
  ) async {
    cancellation.check();
    final value = await servers.diagnosticNetwork(node, core, {
      'stage': stage,
      'host': target.host,
      'port': target.port,
      'serverName': target.serverName,
      'remote': target.remote,
      'tls13': target.tls13,
      'addresses': addresses,
    }, cancellation: cancellation.whenCancelled);
    cancellation.check();
    return value;
  }

  DiagnosticProbeResult _result(Map<String, dynamic> value) {
    final state = DiagnosticState.values
        .where((s) => s.name == value['state'])
        .firstOrNull;
    const codes = {
      'dns_ready',
      'dns_failed',
      'dns_timeout',
      'target_invalid',
      'target_private',
      'tcp_ready',
      'tcp_failed',
      'tcp_timeout',
      'tls_ready',
      'tls_failed',
      'tls_timeout',
      'tls_certificate_invalid',
      'tls13_required',
      'tls_unavailable',
      'openssl_missing',
      'check_failed',
      'certificate_invalid',
      'tls_version',
      'target_not_public',
      'address_ready',
      'tcp_refused',
      'tls_name_mismatch',
      'tls_not_yet_valid',
      'tls_expired',
      'tls_untrusted',
    };
    if (state == null || !codes.contains(value['code']))
      throw const ApiException('route_node_protocol', status: 502);
    return DiagnosticProbeResult(state, value['code'] as String, {
      'node': node,
      if (value['details'] is Map)
        for (final entry in (value['details'] as Map).entries)
          if (const {
                'target',
                'sni',
                'addresses',
                'address',
                'protocol',
                'cipher',
                'purpose',
              }.contains(entry.key) &&
              entry.value is String &&
              (entry.value as String).length <= 1024)
            entry.key as String: entry.value as String,
    });
  }

  @override
  Future<DiagnosticResolution> resolve(
    DiagnosticTlsTarget target,
    DiagnosticCancellation cancellation,
  ) async {
    final value = await _request('dns', target, [], cancellation);
    final result = _result(value);
    return DiagnosticResolution(
      result,
      result.passed
          ? [
              for (final address in value['addresses'] as List? ?? const [])
                if (address is String && address.length <= 64) address,
            ]
          : const [],
    );
  }

  @override
  Future<DiagnosticProbeResult> tcp(
    DiagnosticTlsTarget target,
    List<String> addresses,
    DiagnosticCancellation cancellation,
  ) async => _result(await _request('tcp', target, addresses, cancellation));

  @override
  Future<DiagnosticProbeResult> tls(
    DiagnosticTlsTarget target,
    String address,
    DiagnosticCancellation cancellation,
  ) async => _result(await _request('tls', target, [address], cancellation));

  @override
  Future<DiagnosticProbeResult> listener(
    DiagnosticListener listener,
    int? processId,
    DiagnosticCancellation cancellation,
  ) async => const DiagnosticProbeResult(DiagnosticState.skipped, 'blocked');
}
