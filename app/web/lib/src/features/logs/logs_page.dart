import 'package:jaspr/client.dart';
import 'package:jaspr/dom.dart';
import 'package:sky_ui_shared/sky_ui_shared.dart';
import 'package:web/web.dart' as web;

import '../../shared/components/page_helpers.dart';
import '../../shared/components/primitives.dart';
import '../../shared/localization/strings.dart';

class LogsPage extends StatelessComponent {
  const LogsPage({
    required this.runtimeLogs,
    required this.selectedLogLevels,
    required this.logsLive,
    required this.runtimes,
    required this.selectedLogInstance,
    required this.runtimeBusy,
    required this.runtimeOnline,
    required this.followingLogs,
    required this.onInstance,
    required this.onLevels,
    required this.onFollow,
    required this.onClear,
    required this.scheduleLogTail,
    required this.runtimeMessage,
    super.key,
  });
  final List<CoreLogEntry> runtimeLogs;
  final Set<String> selectedLogLevels;
  final bool logsLive;
  final List<CoreSnapshot> runtimes;
  final String selectedLogInstance;
  final bool runtimeBusy;
  final bool runtimeOnline;
  final bool followingLogs;
  final void Function(String) onInstance;
  final void Function(Set<String>) onLevels;
  final void Function(bool) onFollow;
  final void Function() onClear;
  final void Function() scheduleLogTail;
  final String Function(String) runtimeMessage;
  final t = const AppStrings();
  @override
  Component build(BuildContext context) {
    final entries = runtimeLogs
        .where((entry) => selectedLogLevels.contains(level(entry.level)))
        .toList();
    scheduleLogTail();
    return div([
      heading(
        'logs',
        trailing: div([
          txt(
            t(logsLive ? 'logs.live' : 'logs.reconnecting'),
            classes: 'muted small',
          ),
          select(
            [
              for (final core in runtimes)
                option(
                  [Component.text(core.name)],
                  value: core.instanceId,
                  selected: selectedLogInstance == core.instanceId,
                ),
            ],
            value: selectedLogInstance,
            onChange: (values) => onInstance(values.first),
          ),
          action(
            t('logs.clear'),
            onClear,
            glyph: 'trash',
            disabled: runtimeBusy || runtimeLogs.isEmpty || !runtimeOnline,
          ),
        ], classes: 'log-actions'),
      ),
      div([
        div([
          label([
            input<bool>(
              type: InputType.checkbox,
              checked: selectedLogLevels.length == 6,
              onChange: (checked) => onLevels(
                checked
                    ? {'trace', 'debug', 'info', 'warning', 'error', 'fatal'}
                    : {},
              ),
            ),
            txt(t('logs.all')),
          ], classes: 'log-level-option'),
          for (final entry in [
            ('trace', 'TRACE'),
            ('debug', 'DEBUG'),
            ('info', 'INFO'),
            ('warning', 'WARN'),
            ('error', 'ERROR'),
            ('fatal', 'FATAL'),
          ])
            label([
              input<bool>(
                type: InputType.checkbox,
                checked: selectedLogLevels.contains(entry.$1),
                onChange: (checked) {
                  final levels = {...selectedLogLevels};
                  if (checked) {
                    levels.add(entry.$1);
                  } else {
                    levels.remove(entry.$1);
                  }
                  onLevels(levels);
                },
              ),
              txt(entry.$2),
            ], classes: 'log-level-option'),
        ], classes: 'log-level-filters'),
        action(
          t('logs.latest'),
          () => onFollow(true),
          glyph: 'down',
          disabled: followingLogs,
        ),
      ], classes: 'log-toolbar'),
      div(
        [
          if (entries.isEmpty)
            p([
              Component.text(
                t(runtimeLogs.isEmpty ? 'logs.empty' : 'logs.noMatches'),
              ),
            ], classes: 'muted log-empty'),
          for (final entry in entries)
            div([
              txt(
                '${entry.time.toLocal().hour.toString().padLeft(2, '0')}:${entry.time.toLocal().minute.toString().padLeft(2, '0')}:${entry.time.toLocal().second.toString().padLeft(2, '0')}',
                classes: 'mono log-time',
              ),
              txt(
                entry.level.toUpperCase(),
                classes: 'log-level level-${level(entry.level)}',
              ),
              txt(
                entry.source == 'panel'
                    ? runtimeMessage(entry.message)
                    : entry.message,
                classes: 'log-message',
              ),
            ], classes: 'log-row'),
        ],
        classes: 'panel log-panel runtime-log',
        events: {
          'scroll': (event) {
            final target = event.currentTarget as web.HTMLElement;
            final follows =
                target.scrollHeight - target.scrollTop - target.clientHeight <
                48;
            if (followingLogs != follows) onFollow(follows);
          },
        },
      ),
    ], classes: 'logs-page');
  }

  String level(String value) => switch (value.toLowerCase()) {
    'warn' => 'warning',
    'panic' => 'fatal',
    _ => value.toLowerCase(),
  };
}
