import 'dart:js_interop';

import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:qr/qr.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:web/web.dart' as web;

import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';

class ShareContent extends StatelessComponent {
  const ShareContent({
    required this.sharing,
    required this.shareLoading,
    required this.shareData,
    required this.shareSelection,
    required this.onSelection,
    required this.notify,
    super.key,
  });
  final Recipient sharing;
  final bool shareLoading;
  final RecipientShare? shareData;
  final String shareSelection;
  final void Function(String) onSelection;
  final void Function(String) notify;
  final t = const AppStrings();
  @override
  Component build(BuildContext context) {
    final user = sharing;
    if (!user.enabled) return p([Component.text(t('share.disabled'))]);
    if (shareLoading) return p([Component.text(t('runtime.loading'))]);
    if (shareData == null) return div([]);
    final selected = int.tryParse(shareSelection) ?? -1;
    final artifact = selected >= 0 && selected < shareData!.links.length
        ? shareData!.links[selected]
        : null;
    final url = selected >= 0 && selected < shareData!.links.length
        ? shareData!.links[selected].payload
        : shareData!.subscriptionUrl;
    final qr = QrImage(
      QrCode.fromData(data: url, errorCorrectLevel: QrErrorCorrectLevel.M),
    );
    final size = qr.moduleCount + 8;
    return div([
      p([
        Component.text(t('share.description', {'name': user.name})),
      ]),
      select(
        [
          option(
            [Component.text(t('share.subscription'))],
            value: '-1',
            selected: shareSelection == '-1',
          ),
          for (var i = 0; i < shareData!.links.length; i++)
            option(
              [Component.text(shareData!.links[i].name)],
              value: '$i',
              selected: shareSelection == '$i',
            ),
        ],
        value: shareSelection,
        onChange: (v) => onSelection(v.first),
        attributes: {'aria-label': t('share.type')},
      ),
      div([
        el(
          'svg',
          [
            el(
              'rect',
              [],
              attributes: {'width': '$size', 'height': '$size', 'fill': '#fff'},
            ),
            for (var row = 0; row < qr.moduleCount; row++)
              for (var col = 0; col < qr.moduleCount; col++)
                if (qr.isDark(row, col))
                  el(
                    'rect',
                    [],
                    attributes: {
                      'x': '${col + 4}',
                      'y': '${row + 4}',
                      'width': '1',
                      'height': '1',
                      'fill': '#111',
                    },
                  ),
          ],
          attributes: {
            'viewBox': '0 0 $size $size',
            'shape-rendering': 'crispEdges',
            'role': 'img',
            'aria-label': url,
          },
        ),
      ], classes: 'qr-code'),
      txt(
        artifact?.content != null
            ? 'AmneziaWG 3.1 · .conf'
            : selected < 0
            ? t('share.format')
            : t('share.uriFormat', {
                'protocol': Uri.parse(url).scheme.toUpperCase(),
              }),
        classes: 'muted small',
      ),
      div([
        input<String>(
          value: url,
          attributes: {
            'readonly': '',
            'aria-label': t(
              selected < 0 ? 'share.subscriptionUrl' : 'share.uri',
            ),
          },
        ),
        iconButton('copy', t('common.copy'), () async {
          try {
            await web.window.navigator.clipboard.writeText(url).toDart;
            notify(t('common.copied'));
          } catch (_) {
            notify(t('common.copyFailed'));
          }
        }),
      ], classes: 'copy-field'),
      if (artifact?.content != null)
        action(t('maintenance.download'), () {
          final blob = web.Blob(
            [url.toJS].toJS,
            web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
          );
          final objectUrl = web.URL.createObjectURL(blob);
          final link = web.HTMLAnchorElement()
            ..href = objectUrl
            ..download = artifact!.filename ?? 'Sky-UI.conf';
          link.click();
          web.URL.revokeObjectURL(objectUrl);
        }, glyph: 'down'),
    ], classes: 'share-content');
  }
}
