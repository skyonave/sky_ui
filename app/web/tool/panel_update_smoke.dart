import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:sky_ui_web/src/api_client.dart';
import 'package:sky_ui_web/src/panel_update_card.dart';

/// Browser fixture using the production update card and HTTP client.
void main() => runApp(const UpdateSmoke(), attachTo: '#app');

class UpdateSmoke extends StatefulComponent {
  const UpdateSmoke({super.key});
  @override
  State<UpdateSmoke> createState() => _UpdateSmoke();
}

class _UpdateSmoke extends State<UpdateSmoke> {
  final api = ApiClient();
  PanelUpdateInfo info = const PanelUpdateInfo(
    currentVersion: '0.6.0-dev.4',
    available: false,
    supported: true,
    checkedAt: '2026-11-01T00:00:00Z',
  );
  bool checking = false, checked = false, confirmation = false;
  String? error;
  Future<void> check() async {
    setState(() => checking = true);
    try {
      final result = await api.panelUpdate(refresh: true);
      setState(() {
        info = result;
        error = null;
        checked = true;
      });
    } on ApiClientException {
      setState(() => error = 'Не удалось проверить обновления');
    } finally {
      setState(() => checking = false);
    }
  }

  @override
  Component build(BuildContext context) => div(
    [
      PanelUpdateCard(
        info: info,
        checking: checking,
        checkedManually: checked,
        checkError: error,
        updateEnabled: true,
        onCheck: check,
        onUpdate: () => setState(() => confirmation = true),
      ),
      if (confirmation) p([Component.text('Подтверждение обновления')]),
    ],
    styles: const Styles(
      width: Unit.pixels(232),
      padding: Padding.all(Unit.pixels(12)),
    ),
  );
}
