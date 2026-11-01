import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:sky_ui_web/src/protocol_field.dart';

/// Browser regression fixture for the production numeric field and step changes.
void main() => runApp(const NumericFieldSmoke(), attachTo: '#app');

class NumericFieldSmoke extends StatefulComponent {
  const NumericFieldSmoke({super.key});
  @override
  State<NumericFieldSmoke> createState() => _NumericFieldSmoke();
}

class _NumericFieldSmoke extends State<NumericFieldSmoke> {
  final draft = <String, String>{'port': '8443'};
  bool review = false;
  @override
  Component build(BuildContext context) => div(
    [
      if (!review)
        ProtocolFieldView(
          field: const ProtocolField(
            'port',
            kind: 'integer',
            minimum: 1,
            maximum: 65535,
            required: true,
          ),
          values: draft,
          onChanged: (value, _) => draft['port'] = value,
        ),
      if (review)
        p([Component.text('Port: ${draft['port']}')], id: 'review-port'),
      button([
        Component.text(review ? 'Назад' : 'Далее'),
      ], onClick: () => setState(() => review = !review)),
    ],
    styles: const Styles(
      padding: Padding.all(Unit.pixels(32)),
      maxWidth: Unit.pixels(600),
    ),
  );
}
