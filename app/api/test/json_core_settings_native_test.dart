import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sky_ui_api/src/cores/sing_box_settings.dart';
import 'package:sky_ui_api/src/cores/xray_settings.dart';
import 'package:test/test.dart';
import 'support/socks_probe.dart';

void main() {
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
        Process? process;
        final logs = StringBuffer();

        Future<({int owned, int foreign})> start(
          Map<String, String> input, {
          bool run = true,
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
          if (id == 'xray') {
            XraySettings.apply(base, ['sky-test'], values);
          } else {
            SingBoxSettings.apply(base, ['sky-test'], values);
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
