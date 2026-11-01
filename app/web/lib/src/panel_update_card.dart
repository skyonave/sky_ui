import 'package:jaspr/jaspr.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'i18n.dart';
import 'ui.dart';

class PanelUpdateCard extends StatelessComponent {
  const PanelUpdateCard({
    required this.info,
    required this.onCheck,
    required this.onUpdate,
    this.checking = false,
    this.updating = false,
    this.busy = false,
    this.updateEnabled = false,
    this.checkedManually = false,
    this.checkError,
    this.updateError,
    super.key,
  });
  final PanelUpdateInfo? info;
  final void Function() onCheck, onUpdate;
  final bool checking, updating, busy, updateEnabled, checkedManually;
  final String? checkError, updateError;
  static const t = AppStrings();

  @override
  Component build(BuildContext context) {
    final available = info?.available == true && checkError == null;
    final status = updating
        ? t('panelUpdate.running')
        : checking
        ? t('panelUpdate.checking')
        : checkError ??
              updateError ??
              (available
                  ? t('panelUpdate.available', {
                      'version': info!.latestVersion!,
                    })
                  : info?.supported == false
                  ? t('feature.unavailable')
                  : checkedManually
                  ? t('panelUpdate.current')
                  : '');
    return div([
      txt(t('panelUpdate.title'), classes: 'small'),
      div(
        [Component.text(status)],
        classes: 'sidebar-update-status muted small',
        attributes: {'role': 'status', 'aria-live': 'polite'},
      ),
      action(
        t(
          checking
              ? 'panelUpdate.checkingAction'
              : available
              ? 'panelUpdate.update'
              : 'panelUpdate.check',
        ),
        available ? onUpdate : onCheck,
        glyph: available ? 'down' : 'refresh',
        classes: 'button ${available ? 'primary' : ''}',
        disabled:
            checking ||
            updating ||
            busy ||
            (available ? !updateEnabled : info?.supported == false),
      ),
    ], classes: 'sidebar-update');
  }
}
