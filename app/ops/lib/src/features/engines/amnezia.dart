import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../platform/host.dart';
import 'amnezia_presence.dart';

final awgTable = Platform.environment['SKY_UI_NODE_MODE'] == '1'
    ? 'sky_ui_node_awg'
    : 'sky_ui_awg';

// iproute2 emits host routes without /32, including DHCP-provided DNS routes.
({int ip, int prefix, int network, int broadcast})? awgRoute(
  String destination,
) => destination == 'default'
    ? null
    : ipv4(destination, cidr: destination.contains('/'));
final awgOptions = {
  'Jc': 'jc',
  'Jmin': 'jmin',
  'Jmax': 'jmax',
  for (var i = 1; i <= 4; i++) ...{'S$i': 's$i', 'H$i': 'h$i'},
  for (var i = 1; i <= 5; i++) 'I$i': 'i$i',
  'ContentPaddingAddition': 'content_padding_addition',
  'RandomTrailers': 'random_trailers',
  'DisableCookies': 'disable_cookies',
  'RekeyAfterTime': 'rekey_after_time',
  'RekeyTimeout': 'rekey_timeout',
  'RejectAfterTime': 'reject_after_time',
  'KeepaliveTimeout': 'keepalive_timeout',
  'MaxHandshakeAttempts': 'max_handshake_attempts',
};
final awgBounds = {
  'Jc': (0, 128),
  'Jmin': (0, 1280),
  'Jmax': (0, 1280),
  for (var i = 1; i <= 4; i++) ...{'S$i': (12, 1024), 'H$i': (1, 4294967295)},
  'RekeyAfterTime': (10, 86400),
  'RekeyTimeout': (1, 120),
  'RejectAfterTime': (20, 172800),
  'KeepaliveTimeout': (1, 120),
  'MaxHandshakeAttempts': (1, 128),
};
void awgRequire(bool condition) =>
    require(condition, 'amnezia_configuration_invalid');
String awgKey(Object? value) {
  awgRequire(
    value is String && RegExp(r'^[A-Za-z0-9+/]{43}=$').hasMatch(value),
  );
  final bytes = base64.decode(value as String);
  awgRequire(bytes.length == 32);
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

({int ip, int prefix, int network, int broadcast}) ipv4(
  String address, {
  bool cidr = true,
}) {
  final parts = address.split('/'), octets = parts.first.split('.');
  awgRequire(
    parts.length == (cidr ? 2 : 1) &&
        octets.length == 4 &&
        octets.every(
          (x) =>
              RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(x) &&
              int.parse(x) < 256,
        ),
  );
  final prefix = cidr ? int.parse(parts[1]) : 32;
  awgRequire(prefix >= 0 && prefix <= 32);
  final ip = octets.fold<int>(0, (a, b) => (a << 8) | int.parse(b)),
      mask = prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) & 0xffffffff;
  final net = ip & mask;
  return (
    ip: ip,
    prefix: prefix,
    network: net,
    broadcast: net | (~mask & 0xffffffff),
  );
}

String ipv4Text(int ip) => [24, 16, 8, 0].map((n) => (ip >> n) & 255).join('.');
void signature(String text) {
  final pattern = RegExp(
    r'<(?:b 0x([a-fA-F0-9]+)|(r|rd|rc) ([0-9]{1,4})|(t))>',
  );
  var offset = 0, size = 0;
  for (final m in pattern.allMatches(text)) {
    awgRequire(m.start == offset);
    offset = m.end;
    if (m[1] != null) {
      awgRequire(m[1]!.length % 2 == 0);
      size += m[1]!.length ~/ 2;
    } else {
      size += m[3] == null ? 4 : int.parse(m[3]!);
    }
    awgRequire(size <= 1280);
  }
  awgRequire(offset == text.length);
}

void exactKeys(Map value, Set<String> keys) =>
    awgRequire(value.length == keys.length && keys.every(value.containsKey));
Map<String, dynamic> validateAwg(Object? value) {
  final config = object(value);
  exactKeys(config, {'version', 'interfaces'});
  awgRequire(
    config['version'] == '3.1' &&
        config['interfaces'] is List &&
        (config['interfaces'] as List).length <= 32,
  );
  final names = <String>{},
      ports = <int>{},
      networks = <({int start, int end})>[];
  for (final v in config['interfaces']) {
    final i = object(v);
    exactKeys(i, {
      'name',
      'address',
      'port',
      'mtu',
      'privateKey',
      'headerProtectionKey',
      'options',
      'peers',
      if (i.containsKey('routing')) 'routing',
    });
    awgRequire(
      i['name'] is String &&
          RegExp(r'^skyawg[a-f0-9]{8}$').hasMatch(i['name']) &&
          names.add(i['name']),
    );
    final a = ipv4(i['address'] as String), ip = a.ip;
    awgRequire(
      ((ip >> 24) == 10 || (ip >> 20) == 0xac1 || (ip >> 16) == 0xc0a8) &&
          a.prefix >= 24 &&
          a.prefix <= 30 &&
          ip != a.network &&
          ip != a.broadcast,
    );
    awgRequire(
      !networks.any((n) => a.network <= n.end && n.start <= a.broadcast),
    );
    networks.add((start: a.network, end: a.broadcast));
    awgRequire(
      i['port'] is int &&
          i['port'] >= 1 &&
          i['port'] <= 65535 &&
          ports.add(i['port']),
    );
    awgRequire(i['mtu'] is int && i['mtu'] >= 1280 && i['mtu'] <= 1420);
    awgKey(i['privateKey']);
    awgKey(i['headerProtectionKey']);
    if (i.containsKey('routing')) validateAwgRouting(i['routing']);
    final options = object(i['options']);
    awgRequire(options.keys.every(awgOptions.containsKey));
    for (final entry in options.entries) {
      final name = entry.key, text = entry.value;
      awgRequire(
        text is String &&
            text.length <= 2048 &&
            !RegExp('[\n\r\x00]').hasMatch(text),
      );
      if (['RandomTrailers', 'DisableCookies'].contains(name))
        awgRequire(text == 'true' || text == 'false');
      else if (RegExp(r'^I[1-5]$').hasMatch(name))
        signature(text);
      else if (name == 'ContentPaddingAddition') {
        awgRequire(RegExp(r'^[0-9]{1,4}(?:-[0-9]{1,4})?$').hasMatch(text));
        final bounds = (text as String).split('-').map(int.parse).toList();
        awgRequire(
          bounds.every((n) => n <= 4096) && bounds.first <= bounds.last,
        );
      } else {
        final bounds = awgBounds[name]!;
        awgRequire(
          RegExp(r'^[0-9]{1,10}$').hasMatch(text) &&
              int.parse(text) >= bounds.$1 &&
              int.parse(text) <= bounds.$2,
        );
      }
    }
    awgRequire(
      awgBounds.keys.every(options.containsKey) &&
          int.parse(options['Jmin']) <= int.parse(options['Jmax']) &&
          int.parse(options['RekeyAfterTime']) <
              int.parse(options['RejectAfterTime']),
    );
    awgRequire(i['peers'] is List && (i['peers'] as List).length <= 253);
    final addresses = <int>{}, keys = <String>{};
    for (final v in i['peers']) {
      final peer = object(v);
      exactKeys(peer, {'publicKey', 'presharedKey', 'address'});
      final key = awgKey(peer['publicKey']);
      awgKey(peer['presharedKey']);
      final p = ipv4(peer['address'] as String);
      awgRequire(
        p.prefix == 32 &&
            p.ip > a.network &&
            p.ip < a.broadcast &&
            p.ip != a.ip &&
            addresses.add(p.ip) &&
            keys.add(key),
      );
    }
  }
  return config;
}

void validateAwgRouting(Object? value) {
  final policy = object(value);
  exactKeys(policy, {'fallback', 'rules'});
  const actions = {'next', 'direct', 'block'};
  final rules = policy['rules'];
  awgRequire(
    actions.contains(policy['fallback']) && rules is List && rules.length <= 32,
  );
  for (final raw in rules as List) {
    final rule = object(raw);
    exactKeys(rule, {'type', 'target', 'action'});
    final target = rule['target'] as String;
    awgRequire(actions.contains(rule['action']));
    switch (rule['type']) {
      case 'cidr':
        awgRequire(RegExp(r'^[0-9.]+/\d{1,2}$').hasMatch(target));
        ipv4(target);
      case 'network':
        awgRequire(target == 'tcp' || target == 'udp');
      case 'port':
        final port = int.tryParse(target);
        awgRequire(
          RegExp(r'^\d{1,5}$').hasMatch(target) &&
              port != null &&
              port >= 1 &&
              port <= 65535,
        );
      default:
        awgRequire(false);
    }
  }
}

String awgNftRules(Map<String, dynamic> config) {
  final rules = StringBuffer()
    ..writeln('add table ip $awgTable { comment "Managed by Sky UI"; }')
    ..writeln(
      'add chain ip $awgTable postrouting { type nat hook postrouting priority srcnat; policy accept; }',
    );
  final interfaces = (config['interfaces'] as List).cast<Map>();
  if (interfaces.isNotEmpty) {
    rules.writeln(
      'add set ip $awgTable $awgActiveSet { type ipv4_addr; flags dynamic,timeout; timeout 10s; size 8192; }',
    );
    for (final hook in ['input', 'forward', 'postrouting']) {
      rules.writeln(
        'add chain ip $awgTable traffic_$hook { type filter hook $hook priority filter; policy accept; }',
      );
    }
  }
  for (final i in interfaces) {
    final net = ipv4(i['address'] as String);
    final name = i['name'] as String;
    rules.writeln(
      'add rule ip $awgTable postrouting ip saddr ${ipv4Text(net.network)}/${net.prefix} oifname != "$name" masquerade',
    );
    if (i['routing'] case final Map policy) {
      rules.writeln('add chain ip $awgTable $name');
      for (final hook in ['input', 'forward']) {
        rules.writeln(
          'add rule ip $awgTable traffic_$hook iifname "$name" jump $name',
        );
      }
      for (final rule in (policy['rules'] as List).cast<Map>()) {
        final target = rule['target'];
        final condition = switch (rule['type']) {
          'cidr' => _awgDestination(target as String),
          'port' =>
            'meta l4proto { tcp, udp } th dport ${int.parse(target as String)}',
          _ => 'meta l4proto $target',
        };
        final verdict = rule['action'] == 'block' ? 'drop' : 'return';
        rules.writeln('add rule ip $awgTable $name $condition $verdict');
      }
      if (policy['fallback'] == 'block') {
        rules.writeln('add rule ip $awgTable $name drop');
      }
    }
    for (final hook in ['input', 'forward']) {
      rules.writeln(
        'add rule ip $awgTable traffic_$hook iifname "$name" update @$awgActiveSet { ip saddr }',
      );
    }
    rules.writeln(
      'add rule ip $awgTable traffic_postrouting oifname "$name" update @$awgActiveSet { ip daddr }',
    );
  }
  return rules.toString();
}

String _awgDestination(String target) {
  final network = ipv4(target);
  return 'ip daddr ${ipv4Text(network.network)}/${network.prefix}';
}

Map<String, dynamic> loadAwg(String path) =>
    validateAwg(jsonDecode(readText(path, 4 * 1024 * 1024)));
Uint8List uapiPayload(Map<String, dynamic> interface) {
  final lines = [
    'set=1',
    'private_key=${awgKey(interface['privateKey'])}',
    'listen_port=${interface['port']}',
    'header_protection_key=${awgKey(interface['headerProtectionKey'])}',
    'replace_peers=true',
  ];
  for (final entry in object(interface['options']).entries)
    lines.add(
      '${awgOptions[entry.key]}=${entry.value == 'true'
          ? '1'
          : entry.value == 'false'
          ? '0'
          : entry.value}',
    );
  for (final v in interface['peers']) {
    final p = object(v);
    lines.addAll([
      'public_key=${awgKey(p['publicKey'])}',
      'preshared_key=${awgKey(p['presharedKey'])}',
      'replace_allowed_ips=true',
      'allowed_ip=${p['address']}',
    ]);
  }
  return Uint8List.fromList(utf8.encode('${lines.join('\n')}\n\n'));
}

Future<void> cleanupAwgTable() async {
  final result = await command([
    'nft',
    '-j',
    'list',
    'table',
    'ip',
    awgTable,
  ], check: false);
  if (result.exitCode == 0) {
    final value = object(jsonDecode(result.stdout as String));
    var owned = (value['nftables'] as List).any(
      (v) =>
          v['table']?['family'] == 'ip' &&
          v['table']?['name'] == awgTable &&
          v['table']?['comment'] == 'Managed by Sky UI',
    );
    // nftables 0.9.x omits table comments from JSON but retains them in text.
    if (!owned)
      owned = awgTableOwnershipText(
        await run(['nft', 'list', 'table', 'ip', awgTable]),
        awgTable,
      );
    awgRequire(owned);
    await run(['nft', 'delete', 'table', 'ip', awgTable]);
  }
}

bool awgTableOwnershipText(String text, String table) =>
    {'sky_ui_awg', 'sky_ui_node_awg'}.contains(table) &&
    RegExp(
      '^table ip ${RegExp.escape(table)} \\{\\r?\\n[ \\t]+comment "Managed by Sky UI";?\\r?\\n',
    ).hasMatch(text);

Future<void> runAwg(String configuration, String binary) async {
  awgRequire(host.uid() == 0);
  final config = loadAwg(configuration);
  final children = <Process>[], owned = <String>[];
  var stopping = false;
  final terms = ProcessSignal.sigterm.watch().listen((_) => stopping = true),
      ints = ProcessSignal.sigint.watch().listen((_) => stopping = true);
  try {
    await cleanupAwgTable();
    if ((config['interfaces'] as List).isNotEmpty) {
      await command(['nft', '-f', '-'], input: awgNftRules(config));
    }
    final routes = jsonDecode(
      await run(['ip', '-j', 'route', 'show', 'table', 'main']),
    ) as List;
    for (final v in config['interfaces']) {
      final i = object(v), name = i['name'] as String;
      awgRequire(!exists('/sys/class/net/$name'));
      final net = ipv4(i['address'] as String);
      for (final route in routes) {
        final dst = route['dst'] ?? 'default';
        final r = awgRoute(dst as String);
        if (r != null) {
          awgRequire(
            !(net.network <= r.broadcast && r.network <= net.broadcast),
          );
        }
      }
      final child = await Process.start(
        binary,
        ['-f', name],
        environment: {'PATH': cleanEnvironment['PATH']!, 'LOG_LEVEL': 'error'},
        includeParentEnvironment: false,
        mode: ProcessStartMode.inheritStdio,
      );
      children.add(child);
      owned.add(name);
      var ended = false;
      unawaited(child.exitCode.then((_) => ended = true));
      final path = '/var/run/amneziawg/$name.sock',
          deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!exists(path) && !ended && DateTime.now().isBefore(deadline))
        await sleep(50);
      awgRequire(exists(path) && !ended);
      final socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
        timeout: const Duration(seconds: 5),
      );
      try {
        socket.add(uapiPayload(i));
        await socket.flush();
        final response = <int>[];
        await for (final chunk in socket.timeout(const Duration(seconds: 5))) {
          response.addAll(chunk);
          awgRequire(response.length <= 4096);
          if (response.length >= 2 &&
              response[response.length - 1] == 10 &&
              response[response.length - 2] == 10)
            break;
        }
        awgRequire(utf8.decode(response) == 'errno=0\n\n');
      } finally {
        socket.destroy();
      }
      await run(['ip', 'address', 'add', i['address'] as String, 'dev', name]);
      await run(['ip', 'link', 'set', 'dev', name, 'mtu', '${i['mtu']}', 'up']);
    }
    if (owned.isNotEmpty) {
      final root = Platform.environment['SKY_UI_NODE_MODE'] == '1'
          ? '/var/lib/sky-ui-node/amneziawg-network'
          : '/var/lib/sky-ui-amneziawg-network';
      host.mkdir(root, mode: 0x1c0);
      host.trusted(root, directory: true);
      if (!exists('$root/ip_forward'))
        host.atomic(
          '$root/ip_forward',
          File('/proc/sys/net/ipv4/ip_forward').readAsBytesSync(),
          mode: 0x180,
        );
      File('/proc/sys/net/ipv4/ip_forward').writeAsStringSync('1\n');
    }
    stdout.writeln('AmneziaWG 3.1 ready');
    var failed = false;
    for (final child in children)
      unawaited(child.exitCode.then((_) => failed = true));
    final tracked = {
      for (final i in config['interfaces'] as List)
        for (final p in i['peers'] as List)
          (p['address'] as String).split('/').first: digest(
            utf8.encode('${i['name']}/${awgKey(p['publicKey'])}'),
          ),
    };
    var nextObservation = Duration.zero;
    final clock = Stopwatch()..start();
    while (!stopping) {
      require(!failed, 'amnezia_process_failed');
      if (clock.elapsed >= nextObservation && tracked.isNotEmpty) {
        nextObservation = clock.elapsed + const Duration(seconds: 2);
        await observeAwgTraffic(awgTable, tracked);
      }
      await sleep(200);
    }
  } finally {
    for (final child in children) child.kill();
    for (final child in children) {
      try {
        await child.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        child.kill(ProcessSignal.sigkill);
        await child.exitCode;
      }
    }
    for (final name in owned)
      await command(['ip', 'link', 'delete', 'dev', name], check: false);
    try {
      await cleanupAwgTable();
    } finally {
      await terms.cancel();
      await ints.cancel();
    }
  }
}
