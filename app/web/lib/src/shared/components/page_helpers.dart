import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';

import '../localization/strings.dart';
import 'primitives.dart';

const _strings = AppStrings();
Component heading(String key, {Component? trailing}) => div([
  div([
    h1([Component.text(_strings('$key.title'))]),
  ]),
  if (trailing != null) trailing,
], classes: 'page-heading');

Component stat(String label, String value, String glyph, String detail) => div([
  div([txt(label, classes: 'stat-label'), icon(glyph)], classes: 'stat-top'),
  div([txt(value, classes: 'stat-value')], classes: 'stat-bottom'),
], classes: 'stat-card');

Component emptyState(String glyph, String title, [String? description]) => div([
  icon(glyph),
  h3([Component.text(title)]),
  if (description != null) p([Component.text(description)]),
], classes: 'empty-state');

Component plannedSetting(String title, String actionKey) => div([
  div([
    txt(_strings(title)),
    txt(_strings('feature.unavailable'), classes: 'availability-chip'),
  ], classes: 'setting-label'),
  action(_strings(actionKey), () {}, disabled: true),
], classes: 'setting-row');

String bytes(int? value) {
  if (value == null) return '—';
  return value >= 1000000000
      ? '${(value / 1000000000).toStringAsFixed(1)} ${_strings('system.gb')}'
      : '${(value / 1000000).toStringAsFixed(0)} ${_strings('system.mb')}';
}

String rate(double? value) {
  if (value == null) return '—';
  if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(2)} MB/s';
  if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)} KB/s';
  return '${value.toStringAsFixed(0)} B/s';
}

String sessionDevice(String ua) {
  final browser = ua.contains('Edg/')
      ? 'Edge'
      : ua.contains('Firefox/')
      ? 'Firefox'
      : ua.contains('Chrome/')
      ? 'Chrome'
      : ua.contains('Safari/')
      ? 'Safari'
      : ua.contains('Dart/') || ua.contains('Python')
      ? 'CLI'
      : 'Browser';
  final os = ua.contains('Windows')
      ? 'Windows'
      : ua.contains('Android')
      ? 'Android'
      : ua.contains('iPhone')
      ? 'iOS'
      : ua.contains('Mac OS')
      ? 'macOS'
      : ua.contains('Linux')
      ? 'Linux'
      : '';
  return os.isEmpty ? browser : '$browser · $os';
}

String sessionTime(DateTime date) {
  final value = date.toLocal();
  return '${value.day.toString().padLeft(2, '0')}.${value.month.toString().padLeft(2, '0')} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
}
