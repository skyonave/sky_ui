import 'dart:io';
import 'dart:typed_data';

import '../../platform/host.dart';
import '../../shared/artifacts.dart' show targetPlatform;
import '../../shared/progress.dart';

const sniToolVersion = 'v0.2.2';
const sniToolSha =
    '509a834c7132a100440571a10a074a12f93403fa1e359583cdaa2a2edff28a5c';
const sniToolUrl =
    'https://github.com/XTLS/RealiTLScanner/releases/download/v0.2.2/RealiTLScanner-linux-64';

Future<Map<String, dynamic>> installSniTool(
  Reporter reporter, {
  Future<Uint8List> Function(String, int)? fetch,
}) async {
  require(
    Platform.isLinux && targetPlatform() == 'linux-amd64',
    'sni_tool_platform_unsupported',
  );
  reporter.stage('download');
  int? total;
  final bytes = fetch == null
      ? await httpBytes(
          sniToolUrl,
          16 * 1024 * 1024,
          size: (n) => total = n,
          progress: (n) => reporter.transfer(n, total, 'RealiTLScanner'),
        )
      : await fetch(sniToolUrl, 16 * 1024 * 1024);
  reporter.stage('verify');
  require(digest(bytes) == sniToolSha, 'release_checksum_failed');
  require(
    bytes.length > 20 &&
        bytes[0] == 127 &&
        bytes[1] == 69 &&
        bytes[2] == 76 &&
        bytes[3] == 70 &&
        bytes[4] == 2 &&
        bytes[18] == 62 &&
        bytes[19] == 0,
    'release_architecture_invalid',
  );
  const root = '/opt/sky-ui/tools/realitlscanner';
  const slot = '$root/$sniToolVersion';
  reporter.stage('install');
  host.mkdir('/opt/sky-ui/tools');
  host.mkdir(root);
  host.mkdir(slot);
  host.atomic('$slot/realitlscanner', bytes, mode: 0x1ed);
  switchLink('$root/current', slot);
  return {'tool': 'realitlscanner', 'version': sniToolVersion};
}
