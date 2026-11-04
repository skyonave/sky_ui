import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';

import 'strings.dart';

class LanguageSelect extends StatelessComponent {
  const LanguageSelect({required this.onChanged, super.key});

  final void Function(String) onChanged;

  @override
  Component build(BuildContext context) {
    const t = AppStrings();
    return select(
      [
        for (final (code, name) in [('ru', 'Русский'), ('en', 'English')])
          Component.element(
            tag: 'option',
            children: [Component.text(name)],
            attributes: {
              'value': code,
              'lang': code,
              if (code == t.locale) 'selected': '',
            },
          ),
      ],
      value: t.locale,
      attributes: {'aria-label': t('settings.language')},
      onChange: (values) {
        if (values.isNotEmpty) onChanged(values.first);
      },
    );
  }
}
