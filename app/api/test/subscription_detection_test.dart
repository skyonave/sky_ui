import 'package:sky_ui_api/src/panel/client_exporter.dart';
import 'package:sky_ui_api/src/errors.dart';
import 'package:test/test.dart';

void main() {
  test('Clash-family subscription requests receive YAML', () {
    for (final agent in [
      'clash-verge/v2.4.5',
      'ClashVerge/2.4.5',
      'clash.meta',
      'ClashMetaForAndroid/2.11.2',
      'mihomo/1.19.33',
      'FlClash/0.8.92',
      'FlClashX/1.0',
      'Stash/3.0',
      'Clash/1.18',
    ]) {
      expect(subscriptionFormatFor(agent), 'clash', reason: agent);
    }
  });
  test('URI clients take precedence over embedded core names', () {
    for (final agent in [
      'V2Box/10.1 CFNetwork/1',
      'V2BoxiOS/10.1 mihomo/1.19',
      'v2RayTun/2.4.6',
      'v2rayN/7.0',
      'v2rayNG/1.10',
      'Happ/1.63.1',
      'Streisand/1.6',
      'Shadowrocket/2.2',
      'HiddifyNext/2.0',
      'Hiddify/4.1 mihomo/1.19',
      'NekoBox/1.3',
      'NekoBoxForAndroid/1.3 mihomo/1.19',
      'Nekoray/4.0',
      'Karing/1.2',
      'Throne/1.0',
    ]) {
      expect(subscriptionFormatFor(agent), 'v2ray', reason: agent);
    }
  });
  test('anonymous and generic requests use Base64 URI content', () {
    for (final agent in [
      '',
      'Dart/3.10 (dart:io)',
      'okhttp/4.12',
      'curl/8.0',
      'Mozilla/5.0',
      'NotClash/1.0',
    ]) {
      expect(subscriptionFormatFor(agent), 'v2ray', reason: agent);
    }
  });
  test('all subscription URLs are redacted from logs', () {
    final token = List.filled(43, 'a').join();
    for (final suffix in ['', '.yaml', '.txt']) {
      expect(
        redact('https://example.test/s/$token$suffix', const []),
        'https://example.test/s/[redacted]',
      );
    }
  });
}
