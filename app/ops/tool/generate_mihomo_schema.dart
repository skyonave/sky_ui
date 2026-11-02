import 'dart:convert';
import 'dart:io';

import 'package:sky_ui_ops/src/host.dart';
import 'package:sky_ui_ops/src/archives.dart';

import '../../api/lib/src/cores/mihomo_native.g.dart';

Future<void> main(List<String> args) async {
  require(
    args.isEmpty || args.length == 1 && args.single == '--check',
    'request_invalid',
  );
  const version = '1.19.33',
      expected =
          'e7c596b37ff27ec487d19b1920f73e0c97a78067ea35766530ee9659ade72711';
  final root = Directory.fromUri(Platform.script.resolve('../../../')).path;
  final bytes = await httpBytes(
    'https://codeload.github.com/MetaCubeX/mihomo/tar.gz/refs/tags/v$version',
    64 * 1024 * 1024,
  );
  require(digest(bytes) == expected, 'release_checksum_failed');
  final files = tarSelected(
        bytes,
        (name) => name.contains('/listener/inbound/') && name.endsWith('.go'),
        limit: 160 * 1024 * 1024,
        maxFiles: 20000,
      ),
      structs = <String, List<({String key, String kind, bool required})>>{};
  for (final entry in files.entries.where(
    (e) => e.key.contains('/listener/inbound/') && e.key.endsWith('.go'),
  )) {
    for (final type in RegExp(
      r'^type (\w+) struct \{(.*?)^\}',
      multiLine: true,
      dotAll: true,
    ).allMatches(utf8.decode(entry.value))) {
      final fields = <({String key, String kind, bool required})>[];
      for (final line in type[2]!.split('\n')) {
        final m = RegExp(r'\s*(\w+)\s+(\S+)\s+`inbound:"([^"]+)"`')
            .firstMatch(line);
        if (m != null && m[3]!.split(',').first != '-')
          fields.add((
            key: m[3]!.split(',').first,
            kind: m[2]!,
            required: !m[3]!.contains(',omitempty'),
          ));
      }
      structs[type[1]!] = fields;
    }
  }
  List<Map<String, dynamic>> fields(
    String type, [
    List<String> prefix = const [],
  ]) {
    final result = <Map<String, dynamic>>[];
    for (final field in structs[type]!) {
      final path = [...prefix, field.key],
          plain = field.kind.replaceFirst(RegExp(r'^\*'), '');
      if (structs.containsKey(plain))
        result.addAll(fields(plain, path));
      else if (field.kind.startsWith('[]') &&
          structs.containsKey(field.kind.substring(2)))
        result.add({
          'path': path,
          'type': 'rows',
          'required': field.required,
          'children': fields(field.kind.substring(2)),
        });
      else if (field.kind.startsWith('map[string]')) {
        final target = field.kind.substring(11);
        result.add({
          'path': path,
          'type': 'map',
          'required': field.required,
          'children': [
            {
              'path': ['key'],
              'type': 'string',
              'required': true,
            },
            ...structs.containsKey(target)
                ? fields(target)
                : [
                    {
                      'path': ['value'],
                      'type': target,
                      'required': true,
                    },
                  ],
          ],
        });
      } else if (field.kind == 'AuthUsers')
        result.add({'path': path, 'type': 'users', 'required': field.required});
      else {
        require(
          [
            'string',
            'bool',
            'int',
            'uint64',
            'uint32',
            'uint16',
            'int64',
            '[]string',
            '[]int',
            '[]uint32',
            '[]uint16',
            '[]netip.Prefix',
            '[]netip.Addr',
            'C.TUNStack',
          ].contains(plain),
          'upstream_schema_changed',
        );
        result.add({
          'path': path,
          'type': plain,
          'required': field.required,
          'nullable': field.kind.startsWith('*'),
        });
      }
    }
    return result;
  }

  // Preserve the reviewed inventory rather than expanding product scope.
  final generated = File('$root/app/api/lib/src/cores/mihomo_native.g.dart');
  const inventory = mihomoNativeInventory;
  const names = {
    'vless': 'VlessOption',
    'vmess': 'VmessOption',
    'trojan': 'TrojanOption',
    'shadowsocks': 'ShadowSocksOption',
    'snell': 'SnellOption',
    'mieru': 'MieruOption',
    'sudoku': 'SudokuOption',
    'trusttunnel': 'TrustTunnelOption',
    'tuic': 'TuicOption',
    'hysteria2': 'Hysteria2Option',
    'hysteria2-realm': 'Hysteria2RealmServerOption',
    'shadowquic': 'ShadowQuicOption',
    'anytls': 'AnyTLSOption',
    'http': 'HTTPOption',
    'socks': 'SocksOption',
    'mixed': 'MixedOption',
    'redirect': 'RedirOption',
    'tproxy': 'TProxyOption',
    'tun': 'TunOption',
    'tunnel': 'TunnelOption',
  };
  final result = <String, dynamic>{};
  for (final entry in names.entries) {
    final allowed = (inventory[entry.key] as List)
        .map((f) => (f['path'] as List).join('.'))
        .toSet();
    result[entry.key] = fields(entry.value)
        .where((f) => allowed.contains((f['path'] as List).join('.')))
        .toList();
    require(
      (result[entry.key] as List).length == allowed.length,
      'upstream_schema_changed',
    );
  }
  if (args.contains('--check')) {
    require(
      jsonEncode(inventory) == jsonEncode(result),
      'generated_schema_outdated',
    );
    stdout.writeln('Pinned listener inventory matches the Dart generator.');
    return;
  }
  generated.writeAsStringSync(
    '// Generated by tool/generate_mihomo_schema.dart from MetaCubeX/mihomo v$version.\n// Curated native options; UI policy and defaults are defined separately.\nconst mihomoNativeInventory=<String,List<Map<String,dynamic>>>${const JsonEncoder.withIndent('  ').convert(result)};\n',
  );
  stdout.writeln('Generated ${result.length} pinned listener definitions.');
}
