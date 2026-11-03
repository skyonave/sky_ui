import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:sky_ui_ops/src/platform/host.dart';
import 'package:sky_ui_ops/src/shared/archives.dart';
import 'package:sky_ui_ops/src/shared/artifacts.dart';
import 'package:sky_ui_ops/src/features/engines/amnezia.dart';
import 'package:sky_ui_ops/src/features/updates/release_catalog.dart';
import 'package:sky_ui_ops/src/features/storage/retention.dart';

Uint8List bytes(String text) => Uint8List.fromList(utf8.encode(text));
Map<String, dynamic> clone(Map<String, dynamic> value) =>
    object(jsonDecode(jsonEncode(value)));
final fails = isA<OpsError>();
Map<String, dynamic> awgFixture() {
  final key = base64.encode(List.generate(32, (i) => i));
  return {
    'version': '3.1',
    'interfaces': [
      {
        'name': 'skyawg1234abcd',
        'address': '10.66.0.1/24',
        'port': 35001,
        'mtu': 1280,
        'privateKey': key,
        'headerProtectionKey': key,
        'options': {
          for (final entry in awgBounds.entries) entry.key: '${entry.value.$1}',
          'Jmin': '40',
          'Jmax': '70',
          'RekeyAfterTime': '120',
          'RejectAfterTime': '180',
          'ContentPaddingAddition': '0-32',
          'RandomTrailers': 'true',
          'DisableCookies': 'true',
        },
        'peers': [
          {'publicKey': key, 'presharedKey': key, 'address': '10.66.0.2/32'},
        ],
      },
    ],
  };
}

Map<String, dynamic> release(
  String tag, {
  bool draft = false,
  bool prerelease = true,
  String platform = 'linux-amd64',
}) {
  final files = {
    'install.sh': bytes('#!/bin/sh\nexit 0\n'),
    'sky-ui-$platform.tar.gz': bytes('fixture'),
  };
  for (final entry in files.entries.toList())
    files['${entry.key}.sha256'] = bytes(
      '${digest(entry.value)}  ${entry.key}\n',
    );
  return {
    'tag_name': tag,
    'draft': draft,
    'prerelease': prerelease,
    'assets': [
      for (final entry in files.entries)
        {
          'name': entry.key,
          'state': 'uploaded',
          'size': entry.value.length,
          'digest': 'sha256:${digest(entry.value)}',
          'browser_download_url':
              '$repository/releases/download/$tag/${entry.key}',
        },
    ],
  };
}

void main() {
  test('managed temporary names cover Bash and Dart workspaces only', () {
    for (final name in [
      'sky-ui-install.Abc12345',
      'sky-ui-build.Abc12345',
      'sky-ui-build-AbC123',
    ]) {
      expect(managedTemporaryPattern.hasMatch(name), isTrue);
    }
    for (final name in [
      'sky-ui-build-user-data',
      'sky-ui-install.user',
      'other-build-AbC123',
    ]) {
      expect(managedTemporaryPattern.hasMatch(name), isFalse);
    }
  });
  group('SemVer', () {
    for (final pair in [
      ('v0.6.0-dev.10', '0.6.0-dev.9'),
      ('1.0.0', '1.0.0-rc.9'),
      ('1.0.0-beta', '1.0.0-alpha'),
      ('2.0.0', '1.99.99'),
      ('1.0.0-alpha.1', '1.0.0-alpha'),
    ])
      test('${pair.$1} > ${pair.$2}', () {
        expect(compareVersions(pair.$1, pair.$2), greaterThan(0));
        expect(compareVersions(pair.$2, pair.$1), lessThan(0));
      });
    for (final invalid in [
      'v01.0.0',
      'v1.0.0-dev.01',
      '../v1.0.0',
      'v1.0.0;id',
      'v1.0.0-',
    ])
      test('reject $invalid', () => expect(parseVersion(invalid), isNull));
    test('stable never selects prerelease', () async {
      final rows = [
        release('v1.1.0-dev.1'),
        release('v1.0.1', prerelease: false),
      ];
      expect(
        (await candidate(
          '1.0.0',
          'linux-amd64',
          fetch: (_, _) async => bytes(jsonEncode(rows)),
        ))?['tag'],
        'v1.0.1',
      );
    });
    test('ignore drafts, partial uploads and other architectures', () async {
      final incomplete = release('v0.8.0');
      (incomplete['assets'] as List).removeLast();
      final rows = [
        release('v0.9.0', draft: true),
        incomplete,
        release('v0.7.0-dev.10'),
      ];
      final fetch = (String _, int _) async => bytes(jsonEncode(rows));
      expect(
        (await candidate('0.7.0-dev.9', 'linux-amd64', fetch: fetch))?['tag'],
        'v0.7.0-dev.10',
      );
      expect(
        await candidate('0.7.0-dev.10', 'linux-amd64', fetch: fetch),
        isNull,
      );
      expect(
        await candidate('0.7.0-dev.9', 'linux-arm64', fetch: fetch),
        isNull,
      );
    });
    for (final change in [
      {'browser_download_url': 'https://evil.test/install.sh'},
      {'digest': null},
      {'size': 0},
      {'state': 'new'},
    ])
      test('reject substituted release metadata $change', () {
        final r = clone(release('v1.0.0'));
        (r['assets'][0] as Map).addAll(change);
        expect(releaseAssets(r, 'linux-amd64'), isNull);
      });
  });
  group('Backup archives', () {
    final fixture = {
      for (final name in [
        'data/panel.sqlite',
        'data/owner.sqlite',
        'etc/server.env',
        'etc/gateway.secret',
        'etc/controller.secret',
        'etc/Caddyfile',
        'data/cores/mihomo/config.yaml',
      ])
        name: bytes('fixture'),
    };
    test('roundtrip and manifest', () {
      final backup = packBackup(fixture, {'version': 'fixture'}),
          found = unpackBackup(backup.bytes);
      expect(found.files, fixture);
      expect(found.manifest['version'], 'fixture');
    });
    test('checksum is enforced', () {
      final manifest = packBackup(fixture, {}).manifest;
      final altered = {
        ...fixture,
        'data/panel.sqlite': bytes('corrupt'),
        'manifest.json': bytes(jsonEncode(manifest)),
      };
      expect(() => unpackBackup(packTar(altered)), throwsA(fails));
    });
    for (final name in [
      '../etc/shadow',
      '/etc/shadow',
      'etc/../shadow',
      'etc//owner.seed',
      './etc/owner.seed',
      'etc/owner.seed/',
      'etc\\owner.seed',
      'etc/unknown',
      'data/panel.sqlite-wal',
      'edge/data/a/../../secret',
    ])
      test(
        'reject member $name',
        () => expect(validBackupMember(name), isFalse),
      );
    test('incomplete archive rejected', () {
      final backup = packBackup({'etc/server.env': bytes('fixture')}, {});
      expect(() => unpackBackup(backup.bytes), throwsA(fails));
      expect(unpackBackup(backup.bytes, complete: false).files, hasLength(1));
    });
    test('symlinks rejected', () {
      final archive = Archive()
        ..add(ArchiveFile.symlink('etc/owner.seed', '/etc/shadow'));
      final gzip = GZipEncoder().encodeBytes(TarEncoder().encode(archive));
      expect(() => tarFiles(gzip), throwsA(anything));
    });
    test('gzip expansion bounded before tar parsing', () {
      final bomb = GZipEncoder().encodeBytes(List.filled(1048576, 0));
      expect(() => tarFiles(bomb, limit: 1024, maxFiles: 1), throwsA(anything));
    });
  });
  group('streamed verified artifacts', () {
    test('retains selected content only', () {
      final payload = packTar({
        'release/binary': bytes('ELF fixture'),
        'release/unused': Uint8List(1048576),
      });
      final result = tarSelected(payload, (name) => name.endsWith('/binary'));
      expect(result.keys, ['release/binary']);
      expect(utf8.decode(result.values.single), 'ELF fixture');
    });
    test('rejects links even outside the selection', () {
      final archive = Archive()
        ..add(ArchiveFile.symlink('unused', '/etc/shadow'));
      final payload = GZipEncoder().encodeBytes(TarEncoder().encode(archive));
      expect(() => tarSelected(payload, (_) => false), throwsA(anything));
    });
    test('unselected entries still count against size limit', () {
      final payload = packTar({'unused': Uint8List(4096)});
      expect(
        () => tarSelected(payload, (_) => false, limit: 1024),
        throwsA(anything),
      );
    });
  });
  group('AWG privileged input boundary', () {
    test('DHCP host routes and CIDR routes share the overlap check', () {
      expect(awgRoute('default'), isNull);
      expect(awgRoute('8.8.8.8')!.prefix, 32);
      expect(awgRoute('177.177.212.1')!.prefix, 32);
      expect(awgRoute('10.66.0.0/24')!.network, ipv4('10.66.0.1/24').network);
      expect(() => awgRoute('8.8.8.999'), throwsA(anything));
    });
    test('native UAPI and options', () {
      final fixture = validateAwg(awgFixture()),
          payload = utf8.decode(uapiPayload(object(fixture['interfaces'][0])));
      expect(payload, contains('header_protection_key='));
      expect(payload, contains('random_trailers=1\n'));
      expect(payload, contains('allowed_ip=10.66.0.2/32\n'));
      expect(payload, endsWith('\n\n'));
    });
    for (final text in [
      '<r 9999>',
      '<b 0x123>',
      '<r -1>',
      '<r 20>\nlisten_port=80',
      'shell',
    ])
      test(
        'reject signature $text',
        () => expect(() => signature(text), throwsA(anything)),
      );
    test(
      'accept bounded native signature',
      () => signature('<b 0x1234><r 24><rd 4><rc 8><t>'),
    );
    for (final entry in {
      'address': '127.0.0.1/24',
      'privateKey': 'bad',
      'mtu': 65535,
      'name': 'eth0',
      'port': 0,
      'PostUp': 'shell',
    }.entries)
      test('reject interface ${entry.key}', () {
        final f = clone(awgFixture());
        f['interfaces'][0][entry.key] = entry.value;
        expect(() => validateAwg(f), throwsA(anything));
      });
    for (final entry in {
      'S4': '0',
      'Jc': '4294967295',
      'RejectAfterTime': '20',
      'ContentPaddingAddition': '4000-20',
      'RandomTrailers': '1',
      'I1': '<r 9999>',
    }.entries)
      test('reject option ${entry.key}', () {
        final f = clone(awgFixture());
        f['interfaces'][0]['options'][entry.key] = entry.value;
        expect(() => validateAwg(f), throwsA(anything));
      });
    test('reject peer outside subnet', () {
      final f = clone(awgFixture());
      f['interfaces'][0]['peers'][0]['address'] = '192.0.2.1/32';
      expect(() => validateAwg(f), throwsA(anything));
    });
    test('reject duplicate peer', () {
      final f = clone(awgFixture());
      f['interfaces'][0]['peers'].add(
        clone(object(f['interfaces'][0]['peers'][0])),
      );
      expect(() => validateAwg(f), throwsA(anything));
    });
    test('reject overlapping managed networks', () {
      final f = clone(awgFixture()), copy = clone(object(f['interfaces'][0]));
      copy['name'] = 'skyawg1234abce';
      copy['port'] = 35002;
      f['interfaces'].add(copy);
      expect(() => validateAwg(f), throwsA(anything));
    });
  });
  group('Approved artifacts', () {
    Map<String, dynamic> catalog() => {
      'schemaVersion': 1,
      'coreId': 'mihomo',
      'releases': [
        {
          'version': 'v1.19.33',
          'verified': true,
          'panelVersions': ['fixture-panel'],
          'platforms': {
            'linux-amd64': {
              'verified': true,
              'asset': 'mihomo.gz',
              'sha256': 'a' * 64,
            },
          },
        },
      ],
    };
    test('official repository and approved version only', () async {
      final result = await verifiedRelease(
        'mihomo',
        'fixture-panel',
        'linux-amd64',
        fetch: (_, _) async => bytes(jsonEncode(catalog())),
      );
      expect(
        result.url,
        'https://github.com/MetaCubeX/mihomo/releases/download/v1.19.33/mihomo.gz',
      );
    });
    test('wrong platform rejected without upstream fallback', () async {
      expect(
        verifiedRelease(
          'mihomo',
          'fixture-panel',
          'linux-arm64',
          fetch: (_, _) async => bytes(jsonEncode(catalog())),
        ),
        throwsA(fails),
      );
    });
    test('wrong panel rejected', () async {
      expect(
        verifiedRelease(
          'mihomo',
          'other',
          'linux-amd64',
          fetch: (_, _) async => bytes(jsonEncode(catalog())),
        ),
        throwsA(fails),
      );
    });
    test('duplicate approved versions rejected', () async {
      final c = clone(catalog());
      c['releases'].add(clone(object(c['releases'][0])));
      expect(
        verifiedRelease(
          'mihomo',
          'fixture-panel',
          'linux-amd64',
          fetch: (_, _) async => bytes(jsonEncode(c)),
        ),
        throwsA(fails),
      );
    });
    test('unverified release rejected', () async {
      final c = clone(catalog());
      c['releases'][0]['verified'] = false;
      expect(
        verifiedRelease(
          'mihomo',
          'fixture-panel',
          'linux-amd64',
          fetch: (_, _) async => bytes(jsonEncode(c)),
        ),
        throwsA(fails),
      );
    });
    test('checksum mismatch before ELF parsing', () async {
      expect(
        artifactFiles(
          'mihomo',
          'v1.0.0',
          'fixture',
          'a' * 64,
          'linux-amd64',
          fetch: (_, _) async => bytes('bad'),
        ),
        throwsA(fails),
      );
    });
    test('wrong ELF architecture rejected', () async {
      final elf = Uint8List(64)..setRange(0, 6, [127, 69, 76, 70, 2, 1]);
      ByteData.sublistView(elf).setUint16(18, 183, Endian.little);
      final gzip = Uint8List.fromList(GZipEncoder().encodeBytes(elf));
      expect(
        artifactFiles(
          'mihomo',
          'v1.0.0',
          'fixture',
          digest(gzip),
          'linux-amd64',
          fetch: (url, _) async => url == 'fixture' ? gzip : bytes('license'),
        ),
        throwsA(fails),
      );
    });
  });
}
