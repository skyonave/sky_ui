import 'dart:io';
import 'dart:math';
import '../errors.dart';
import 'domain.dart';

/// A point-in-time probe, not a reservation. Activation still checks listeners.
Future<bool> connectionPortAvailable(int port) async {
  final addresses = [InternetAddress.anyIPv4];
  final interfaces = await NetworkInterface.list(includeLoopback: true);
  if (interfaces.any(
    (i) => i.addresses.any((a) => a.type == InternetAddressType.IPv6),
  )) {
    addresses.add(InternetAddress.anyIPv6);
  }
  for (final address in addresses) {
    ServerSocket? tcp;
    RawDatagramSocket? udp;
    try {
      tcp = await ServerSocket.bind(address, port, shared: false);
      udp = await RawDatagramSocket.bind(
        address,
        port,
        reuseAddress: false,
        reusePort: false,
      );
    } on SocketException {
      return false;
    } finally {
      await tcp?.close();
      udp?.close();
    }
  }
  return true;
}

Future<int> randomConnectionPort(
  Set<int> reserved, {
  Future<bool> Function(int) probe = connectionPortAvailable,
  int Function()? next,
}) async {
  final random = Random.secure();
  for (var attempt = 0; attempt < 200; attempt++) {
    final candidate = next?.call() ?? 20000 + random.nextInt(40000);
    if (candidate < 1024 || candidate > 65535 || reserved.contains(candidate))
      continue;
    if (await probe(candidate)) return candidate;
    reserved.add(candidate);
  }
  throw const ApiException('port_unavailable', status: 422);
}

Map<String, String> generateConnectionValue(
  String field,
  String kind,
  Map<String, String> values,
) {
  final random = Random.secure();
  int number(int low, int high) => low + random.nextInt(high - low + 1);
  switch (kind) {
    case 'token':
      return {field: secureToken()};
    case 'path':
      return {field: '/${secureToken(18)}'};
    case 'service':
      return {field: 's${secureToken(16)}'};
    case 'awg-header':
      final occupied = {
        for (var i = 1; i <= 4; i++)
          if ('awg.H$i' != field) int.tryParse(values['awg.H$i'] ?? ''),
      };
      var value = number(5, 4294967295);
      while (occupied.contains(value)) {
        value = number(5, 4294967295);
      }
      return {field: '$value'};
    case 'awg-padding':
      final s1 = number(64, 512);
      var s2 = number(64, 512);
      while (s1 + 148 == s2 + 92) {
        s2 = number(64, 512);
      }
      return {'awg.S1': '$s1', 'awg.S2': '$s2'};
    case 'awg-small-padding':
      return {field: '${number(16, 128)}'};
    case 'awg-junk-count':
      return {field: '${number(3, 12)}'};
    case 'awg-junk-size':
      final low = number(16, 64);
      return {'awg.Jmin': '$low', 'awg.Jmax': '${low + number(32, 128)}'};
    default:
      throw const ApiException('generation_unsupported', status: 422);
  }
}
