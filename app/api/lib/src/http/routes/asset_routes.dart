import 'dart:io';

import 'package:dart_frog/dart_frog.dart';

import '../../bootstrap/server_config.dart';
import '../responses.dart';

const assets = {
  '/': ('index.html', 'text/html; charset=utf-8'),
  '/index.html': ('index.html', 'text/html; charset=utf-8'),
  '/main.dart.js': ('main.dart.js', 'application/javascript; charset=utf-8'),
  '/styles.css': ('styles.css', 'text/css; charset=utf-8'),
  '/fonts/PxPlus_IBM_VGA8.ttf': ('fonts/PxPlus_IBM_VGA8.ttf', 'font/ttf'),
  '/fonts/LICENSE-IBM-VGA.txt': (
    'fonts/LICENSE-IBM-VGA.txt',
    'text/plain; charset=utf-8',
  ),
  '/fonts/ATTRIBUTION.txt': (
    'fonts/ATTRIBUTION.txt',
    'text/plain; charset=utf-8',
  ),
};
void registerAssetRoutes(Router router, ServerConfig config) {
  for (final entry in assets.entries) {
    router.get(entry.key, (_) async {
      final file = File('${config.publicDirectory}/${entry.value.$1}');
      if (!await file.exists()) return failure('asset_missing', 404);
      return Response.stream(
        body: file.openRead(),
        headers: {'content-type': entry.value.$2},
      );
    });
  }
}
