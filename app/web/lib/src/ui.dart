import 'package:jaspr/jaspr.dart';
import 'package:jaspr/dom.dart';

Component el(
  String tag,
  List<Component> children, {
  String? classes,
  Map<String, String>? attributes,
  Map<String, EventCallback>? events,
  Key? key,
}) => Component.element(
  tag: tag,
  classes: classes,
  attributes: attributes,
  events: events,
  children: children,
  key: key,
);

Component txt(String value, {String? classes}) =>
    span([Component.text(value)], classes: classes);

Component icon(String name, {String? classes}) {
  const paths = {
    'github':
        'M9 19c-5 1.5-5-2.5-7-3m14 6v-3.87a3.37 3.37 0 0 0-.94-2.61c3.14-.35 6.44-1.54 6.44-7A5.44 5.44 0 0 0 20 4.77 5.07 5.07 0 0 0 19.91 1S18.73.65 16 2.48a13.38 13.38 0 0 0-7 0C6.27.65 5.09 1 5.09 1A5.07 5.07 0 0 0 5 4.77a5.44 5.44 0 0 0-1.5 3.78c0 5.42 3.3 6.61 6.44 7A3.37 3.37 0 0 0 9 18.13V22',
    'logout': 'M9 3H4v18h5 M10 12h11m-4-4 4 4-4 4',
    'grid': 'M3 3h7v7H3z M14 3h7v7h-7z M3 14h7v7H3z M14 14h7v7h-7z',
    'connections':
        'M8 3H5a2 2 0 0 0-2 2v3m13-5h3a2 2 0 0 1 2 2v3M3 16v3a2 2 0 0 0 2 2h3m8 0h3a2 2 0 0 0 2-2v-3M8 12h8m-4-4v8',
    'users':
        'M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2 M16 3a4 4 0 0 1 0 8 M22 21v-2a4 4 0 0 0-3-3.87 M13 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0',
    'core':
        'M6 6h12v12H6z M9 9h6v6H9z M9 2v4m6-4v4M9 18v4m6-4v4M2 9h4m-4 6h4m12-6h4m-4 6h4',
    'logs': 'M5 3h14v18H5z M8 8h8m-8 4h8m-8 4h5',
    'settings':
        'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8 M10 2h4l1 3 3 1 3 2-1 4 1 4-3 2-3 1-1 3h-4l-1-3-3-1-3-2 1-4-1-4 3-2 3-1z',
    'server': 'M4 3h16v7H4z M4 14h16v7H4z M7 6h.01M7 17h.01 M11 6h6m-6 11h6',
    'plus': 'M12 5v14M5 12h14',
    'search': 'M21 21l-5-5 M18 10a8 8 0 1 1-16 0 8 8 0 0 1 16 0',
    'arrow': 'M7 17 17 7M7 7h10v10',
    'chevron': 'm9 5 7 7-7 7',
    'down': 'm6 9 6 6 6-6',
    'close': 'm6 6 12 12M6 18 18 6',
    'check': 'm5 12 4 4L19 6',
    'copy': 'M9 9h12v12H9z M15 9V3H3v12h6',
    'edit': 'm16 3 5 5L8 21H3v-5z M14 5l5 5',
    'trash': 'M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7m4-7v7',
    'power': 'M12 2v10 M6 5a9 9 0 1 0 12 0',
    'refresh':
        'M20 7v5h-5M4 17v-5h5 M6 7a7 7 0 0 1 12-2l2 7M4 12l2 7a7 7 0 0 0 12-2',
    'shield': 'm12 2 9 4v6c0 5-9 10-9 10S3 17 3 12V6z M8 12l3 3 5-6',
    'globe':
        'M21 12a9 9 0 1 1-18 0 9 9 0 0 1 18 0 M3 12h18 M12 3c5 5 5 13 0 18-5-5-5-13 0-18',
    'link':
        'm10 13 4-4 M8 16l-2 2a4 4 0 0 1-6-6l5-5a4 4 0 0 1 6 0 M13 8l2-2a4 4 0 0 1 6 6l-5 5a4 4 0 0 1-6 0',
    'moon': 'M21 13A9 9 0 0 1 11 3a9 9 0 1 0 10 10',
    'info': 'M12 11v6M12 7h.01 M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0',
    'bolt': 'm13 2-9 12h7l-1 8 10-12h-7z',
    'menu': 'M4 6h16M4 12h16M4 18h16',
  };
  return el(
    'svg',
    [
      el('path', [], attributes: {'d': paths[name] ?? paths['connections']!}),
    ],
    classes: 'icon ${classes ?? ''}',
    attributes: {
      'viewBox': '0 0 24 24',
      'fill': 'none',
      'stroke': 'currentColor',
      'stroke-width': '1.65',
      'stroke-linecap': 'round',
      'stroke-linejoin': 'round',
      'aria-hidden': 'true',
    },
  );
}

Component action(
  String label,
  void Function() onClick, {
  String? glyph,
  String classes = 'button',
  bool disabled = false,
}) => button(
  [if (glyph != null) icon(glyph), Component.text(label)],
  classes: classes,
  onClick: onClick,
  disabled: disabled,
  type: ButtonType.button,
);

Component iconButton(
  String glyph,
  String label,
  void Function() onClick, {
  String classes = 'icon-button',
  bool disabled = false,
}) => button(
  [icon(glyph)],
  classes: classes,
  type: ButtonType.button,
  disabled: disabled,
  onClick: onClick,
  attributes: {'aria-label': label, 'title': label},
);

Component pill(String label, {bool positive = false}) => span([
  span([], classes: 'status-dot'),
  Component.text(label),
], classes: 'pill ${positive ? 'positive' : ''}');

Component enabledCheckbox(
  bool enabled,
  String label,
  void Function() onChange, {
  bool disabled = false,
}) => input<bool>(
  type: InputType.checkbox,
  classes: 'enabled-checkbox',
  checked: enabled,
  disabled: disabled,
  onChange: (_) => onChange(),
  attributes: {'aria-label': label, 'title': label},
);
