import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sky_ui_api/src/application/access/records.dart';
import 'package:sky_ui_api/src/engines/proxy/relay_outbounds.dart';
import 'package:sky_ui_api/src/engines/sing_box/settings.dart';
import 'package:sky_ui_api/src/engines/xray/settings.dart';
import 'package:sky_ui_api/src/engines/xray/traffic.dart';
import 'package:sky_ui_api/src/engines/managed_core.dart';
import 'package:sky_ui_api/src/infrastructure/process/command_runner.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:test/test.dart';
import 'support/socks_probe.dart';

void main() {
  final mihomo = Platform.environment['SKY_UI_MIHOMO_BINARY'];
  for (final id in ['sing-box', 'xray']) {
    final binary =
        Platform.environment[id == 'xray'
            ? 'SKY_UI_XRAY_BINARY'
            : 'SKY_UI_SING_BOX_BINARY'];
    test(
      'native $id DNS, scoped TCP/UDP access and restoration',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'sky-json-settings-',
        );
        final probe = SocksProbe();
        await probe.start();
        Process? process, relayProcess;
        final logs = StringBuffer();

        Future<({int owned, int foreign})> start(
          Map<String, String> input, {
          bool run = true,
          Map<String, NodeRouting> policies = const {},
          RelayLink? relay,
          ManagedCore? trafficCore,
        }) async {
          if (process != null) {
            process!.kill();
            await process!.exitCode;
            process = null;
          }
          final owned = await freeProxyPort(), foreign = await freeProxyPort();
          final base = <String, dynamic>{
            'log': id == 'xray'
                ? {'loglevel': 'warning'}
                : {'level': 'info', 'timestamp': true},
            'inbounds': [
              for (final entry in {
                'sky-test': owned,
                'foreign': foreign,
              }.entries)
                id == 'xray'
                    ? {
                        'tag': entry.key,
                        'listen': '127.0.0.1',
                        'port': entry.value,
                        'protocol': 'socks',
                        'settings': {
                          'auth': 'noauth',
                          'udp': true,
                          'ip': '127.0.0.1',
                        },
                      }
                    : {
                        'tag': entry.key,
                        'listen': '127.0.0.1',
                        'listen_port': entry.value,
                        'type': 'socks',
                      },
            ],
            'outbounds': id == 'xray'
                ? [
                    {
                      'protocol': 'freedom',
                      'tag': 'direct',
                      'settings': {'domainStrategy': 'UseIP'},
                    },
                  ]
                : [
                    {'type': 'direct', 'tag': 'direct'},
                  ],
            'dns': id == 'xray'
                ? {
                    'servers': [
                      {'address': '127.0.0.1', 'port': probe.dns.port},
                    ],
                  }
                : {
                    'servers': [
                      {
                        'type': 'udp',
                        'tag': 'fixture',
                        'server': '127.0.0.1',
                        'server_port': probe.dns.port,
                      },
                    ],
                    'final': 'fixture',
                  },
          };
          final text = jsonEncode(base);
          final values = id == 'xray'
              ? XraySettings.prepare(text, null, input)
              : SingBoxSettings.prepare(text, null, input);
          final relays = relay == null
              ? const <String, Map<String, String>>{}
              : {
                  'sky-test': ProxyRelayOutbounds.apply(base, [
                    relay,
                  ], xray: id == 'xray')['fixture']!,
                };
          if (id == 'xray') {
            if (trafficCore != null) XrayTraffic.configure(base, trafficCore);
            XraySettings.apply(
              base,
              ['sky-test'],
              values,
              policies: policies,
              relays: relays,
            );
          } else {
            SingBoxSettings.apply(
              base,
              ['sky-test'],
              values,
              policies: policies,
              relays: relays,
            );
          }
          if (relay != null) {
            // The isolated echo fixture is on loopback.
            final route = base[id == 'xray' ? 'routing' : 'route'] as Map;
            (route['rules'] as List).removeWhere(
              (rule) => rule.containsKey(id == 'xray' ? 'ip' : 'ip_cidr'),
            );
          }
          final file = File('${root.path}/config.json');
          await file.writeAsString(jsonEncode(base));
          final validation = await Process.run(
            binary!,
            id == 'xray'
                ? ['run', '-test', '-config', file.path]
                : ['check', '-c', file.path],
          );
          expect(
            validation.exitCode,
            0,
            reason:
                '${validation.stdout}\n${validation.stderr}\n${jsonEncode(base)}',
          );
          if (!run) return (owned: owned, foreign: foreign);
          process = await Process.start(
            binary,
            id == 'xray'
                ? ['run', '-config', file.path]
                : ['run', '-c', file.path],
          );
          void collect(String s) {
            if (logs.length < 65536) logs.write(s);
          }

          process!.stdout.transform(utf8.decoder).listen(collect);
          process!.stderr.transform(utf8.decoder).listen(collect);
          var ready = false;
          for (var i = 0; i < 50; i++) {
            try {
              final s = await Socket.connect(
                '127.0.0.1',
                owned,
                timeout: const Duration(milliseconds: 100),
              );
              s.destroy();
              ready = true;
              break;
            } on SocketException {
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
          expect(ready, true, reason: logs.toString());
          return (owned: owned, foreign: foreign);
        }

        try {
          var ports = await start({});
          expect(await probe.tcp(ports.owned), true, reason: logs.toString());
          expect(await probe.tcp(ports.owned, host: '::ffff:127.0.0.1'), true);
          expect(
            await probe.datagram(ports.owned),
            true,
            reason: logs.toString(),
          );
          ports = await start({'blockPrivate': 'true', 'logLevel': 'debug'});
          expect(await probe.tcp(ports.owned), false);
          expect(await probe.tcp(ports.owned, host: '::ffff:127.0.0.1'), false);
          expect(await probe.tcp(ports.owned, host: 'private.test'), false);
          expect(await probe.datagram(ports.owned), false);
          expect(
            await probe.datagram(ports.owned, host: 'private.test'),
            false,
          );
          expect(await probe.tcp(ports.foreign), true);
          expect(await probe.datagram(ports.foreign), true);
          ports = await start({
            'accessRules':
                '[{"type":"domain","target":"private.test","action":"block"}]',
          });
          expect(await probe.tcp(ports.owned, host: 'private.test'), false);
          expect(await probe.tcp(ports.owned), true);
          ports = await start({
            'dnsMode': 'custom',
            'resolvers': 'udp://127.0.0.1:${probe.dns.port}',
          });
          final queries = probe.dnsQueries;
          expect(
            await probe.tcp(ports.owned, host: 'custom.test'),
            true,
            reason: logs.toString(),
          );
          expect(probe.dnsQueries, greaterThan(queries));
          ports = await start({'blockPrivate': 'false', 'dnsMode': 'existing'});
          expect(await probe.tcp(ports.owned, host: 'private.test'), true);
          ports = await start(
            {},
            policies: {
              'sky-test': NodeRouting(
                rules: [
                  const RoutingRule(
                    'domain',
                    'private.test',
                    NodeRouting.block,
                  ),
                  const RoutingRule('network', 'udp', NodeRouting.block),
                  RoutingRule('port', '${probe.http.port}', NodeRouting.direct),
                ],
                fallback: NodeRouting.block,
              ),
            },
          );
          expect(await probe.tcp(ports.owned, host: 'private.test'), false);
          expect(await probe.tcp(ports.owned), true, reason: logs.toString());
          expect(await probe.datagram(ports.owned), false);
          expect(await probe.datagram(ports.foreign), true);
          if (mihomo != null) {
            final port = await freeProxyPort();
            final password = base64.encode(List.filled(32, 42));
            final relay = RelayLink(
              connectionId: 'fixture',
              index: 0,
              destination: '127.0.0.1',
              source: '127.0.0.1',
              port: port,
              password: password,
              inbound: false,
              targetNode: 'exit',
            );
            final file = File('${root.path}/relay.json');
            await file.writeAsString(
              jsonEncode({
                'mode': 'rule',
                'rules': ['MATCH,DIRECT'],
                'listeners': [
                  {
                    'name': 'fixture',
                    'type': 'shadowsocks',
                    'listen': '127.0.0.1',
                    'port': port,
                    'udp': true,
                    'cipher': '2022-blake3-aes-256-gcm',
                    'password': password,
                  },
                ],
              }),
            );
            relayProcess = await Process.start(mihomo, [
              '-d',
              root.path,
              '-f',
              file.path,
            ]);
            relayProcess.stdout.transform(utf8.decoder).listen(logs.write);
            relayProcess.stderr.transform(utf8.decoder).listen(logs.write);
            ports = await start(
              {},
              relay: relay,
              policies: {'sky-test': const NodeRouting(fallback: 'node:exit')},
            );
            expect(await probe.tcp(ports.owned), true, reason: logs.toString());
            expect(
              await probe.datagram(ports.owned),
              true,
              reason: logs.toString(),
            );
            relayProcess.kill();
            await relayProcess.exitCode;
            relayProcess = null;
            expect(await probe.tcp(ports.owned), false);
            expect(await probe.tcp(ports.foreign), true);
          }
          if (id == 'xray' && Platform.isLinux) {
            final core = ManagedCore(
              id: id,
              coreId: id,
              service: 'fixture',
              binary: binary!,
              directory: root.path,
              configuration: '${root.path}/config.json',
              controller: Uri.parse('http://127.0.0.1:0'),
              secret: '',
            );
            ports = await start({}, trafficCore: core);
            final observer = XrayTraffic();
            Future<RecipientPresence?> sample() async => (await observer.sample(
              const NativeCommandRunner(),
              core,
              {('sky-test', null): 'grant'},
            ))?['grant'];
            expect(await sample(), RecipientPresence.offline);
            expect(await probe.tcp(ports.owned), true);
            expect(await sample(), RecipientPresence.online);
          }
          for (final resolver in [
            'https://dns.google/dns-query',
            'tcp://1.1.1.1:53',
            if (id == 'sing-box') 'tls://one.one.one.one',
          ])
            await start({
              'dnsMode': 'custom',
              'resolvers': resolver,
            }, run: false);
          for (final level
              in id == 'xray'
                  ? ['none', 'debug']
                  : ['disabled', 'trace', 'warn', 'panic'])
            await start({'logLevel': level}, run: false);
        } finally {
          if (process != null) {
            process!.kill();
            await process!.exitCode;
          }
          await probe.close();
          if (relayProcess != null) {
            relayProcess.kill();
            await relayProcess.exitCode;
          }
          await root.delete(recursive: true);
        }
      },
      skip: binary == null
          ? 'Set the verified native engine binary environment variable.'
          : false,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}
