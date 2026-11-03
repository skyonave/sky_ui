import 'package:jaspr/dom.dart';
import 'package:jaspr/jaspr.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';

import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';

class EngineCard extends StatelessComponent {
  const EngineCard({
    required this.descriptor,
    required this.onOperation,
    required this.onInstallOrUpdate,
    required this.onRemove,
    this.onSettings,
    this.settingsAvailable = false,
    this.runtime,
    this.feedback,
    this.updateAvailable = false,
    this.maintenanceAvailable = false,
    this.busy = false,
    this.strings = const AppStrings(),
    super.key,
  });

  final CoreDescriptor descriptor;
  final CoreSnapshot? runtime;
  final String? feedback;
  final bool updateAvailable, maintenanceAvailable, busy;
  final AppStrings strings;
  final void Function(CoreOperation) onOperation;
  final void Function() onInstallOrUpdate, onRemove;
  final void Function()? onSettings;
  final bool settingsAvailable;

  @override
  Component build(BuildContext context) {
    final t = strings, value = runtime;
    final installed = value?.binaryAvailable == true;
    final running = installed && value!.processState == CoreProcessState.active;
    final operation = running ? CoreOperation.stop : CoreOperation.start;
    final status = t(
      !installed
          ? 'core.notInstalled'
          : 'runtime.state.${value!.processState.name}',
    );
    final nameId = 'engine-name-${descriptor.id}';
    final memory = !installed || value?.memoryBytes == null
        ? '—'
        : '${(value!.memoryBytes! / 1000000).toStringAsFixed(1)} MB';
    final ready = !installed
        ? '—'
        : t(value!.controllerReady ? 'runtime.ready' : 'runtime.notReady');
    return el(
      'article',
      [
        div([
          div([
            div([icon('core')], classes: 'engine-symbol'),
            div([
              div([
                h2([Component.text(descriptor.name)], id: nameId),
                txt(value?.version ?? '—', classes: 'engine-version mono'),
                a(
                  [icon('github')],
                  classes: 'icon-button engine-repository',
                  href: 'https://github.com/${coreRepositories[descriptor.id]}',
                  target: Target.blank,
                  attributes: {
                    'rel': 'noopener noreferrer',
                    'aria-label': 'GitHub: ${descriptor.name}',
                    'title': 'GitHub: ${descriptor.name}',
                  },
                ),
                iconButton(
                  'settings',
                  '${t('coreSettings.title')}: ${descriptor.name}',
                  onSettings ?? () {},
                  disabled: busy || !installed || !settingsAvailable,
                  classes: 'icon-button engine-settings',
                ),
              ], classes: 'engine-name'),
              txt(
                value?.service ?? 'sky-ui-${descriptor.id}.service',
                classes: 'engine-service muted mono',
              ),
            ], classes: 'engine-identity-text'),
          ], classes: 'engine-identity'),
          div([
            div(
              [pill(status, positive: running)],
              classes:
                  'engine-state ${value?.processState == CoreProcessState.failed ? 'failed' : ''}',
            ),
            div([
              div([
                txt(t('core.ram'), classes: 'muted'),
                txt(memory, classes: 'mono'),
              ], classes: 'engine-readout'),
              div([
                txt(t('runtime.controller'), classes: 'muted'),
                txt(ready),
              ], classes: 'engine-readout'),
            ], classes: 'engine-readouts'),
          ], classes: 'engine-health'),
          div([
            if (installed) ...[
              action(
                t(running ? 'core.stop' : 'core.start'),
                () => onOperation(operation),
                glyph: 'power',
                classes: 'button compact engine-toggle',
                disabled:
                    busy ||
                    value?.platformSupported != true ||
                    !value!.operations.contains(operation),
              ),
              iconButton(
                'refresh',
                '${t('core.restart')}: ${descriptor.name}',
                () => onOperation(CoreOperation.restart),
                classes: 'icon-button engine-restart',
                disabled:
                    busy ||
                    value?.platformSupported != true ||
                    !value!.operations.contains(CoreOperation.restart),
              ),
            ],
            action(
              t(installed ? 'core.updateShort' : 'core.install'),
              onInstallOrUpdate,
              glyph: 'down',
              classes: 'button compact engine-update',
              disabled: busy || !maintenanceAvailable || !updateAvailable,
            ),
            if (installed)
              iconButton(
                'trash',
                '${t('core.remove')}: ${descriptor.name}',
                onRemove,
                classes: 'icon-button engine-remove',
                disabled: busy || !maintenanceAvailable,
              ),
          ], classes: 'engine-actions'),
        ], classes: 'engine-main'),
        div(
          [if (feedback != null) Component.text(feedback!)],
          classes: 'engine-feedback muted',
          attributes: {
            'role': 'status',
            'aria-live': 'polite',
            if (feedback != null) 'title': feedback!,
          },
        ),
      ],
      classes: 'panel engine-panel',
      attributes: {'aria-labelledby': nameId},
    );
  }
}
