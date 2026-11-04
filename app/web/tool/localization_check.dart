import 'package:sky_ui_web/src/shared/localization/strings.dart';

void main() {
  const ru = AppStrings(locale: 'ru'), en = AppStrings(locale: 'en');
  final cyrillic = RegExp(r'[\u0400-\u052f]');
  final placeholder = RegExp(r'\{[\w-]+\}');
  List<String> parameters(String value) =>
      placeholder.allMatches(value).map((m) => m[0]!).toList()..sort();
  final failures = <String>[];
  for (final key in AppStrings.translationKeys) {
    if (en(key) == key || cyrillic.hasMatch(en(key))) {
      failures.add('English translation missing: $key');
    }
    if (parameters(ru(key)).join(',') != parameters(en(key)).join(',')) {
      failures.add('Mismatched placeholders: $key');
    }
  }
  for (final (key, value) in [
    ('nav.connections', 'Connections'),
    ('builder.guideTitle', 'Setup guide'),
    ('core.start', 'Start'),
    (
      'runtime.error.service_failed',
      'The core service failed. Check the systemd logs.',
    ),
  ]) {
    if (en(key) != value) failures.add('Unexpected translation: $key');
  }
  const active = AppStrings();
  AppStrings.defaultLocale = 'en';
  if (active('nav.users') != 'Users' || ru('nav.users') == 'Users')
    failures.add('Locale did not switch correctly.');
  if (failures.isNotEmpty) throw StateError(failures.join('\n'));
  print('English localization and placeholders verified.');
}
