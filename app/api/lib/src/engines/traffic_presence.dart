import 'package:sky_ui_shared/sky_ui_shared.dart';

typedef TrafficSample = ({
  String grant,
  int upload,
  int download,
  DateTime? start,
});

class TrafficPresence {
  static const window = Duration(seconds: 10);
  final _last = <String, DateTime>{};
  Map<String, TrafficSample> _previous = const {};
  DateTime? _sampledAt;

  void observe(Map<String, TrafficSample> samples, DateTime now) {
    final previous = _sampledAt;
    final continuous =
        previous != null &&
        !now.isBefore(previous) &&
        now.difference(previous) < window;
    for (final entry in samples.entries) {
      final value = entry.value;
      final old = _previous[entry.key];
      final delta =
          continuous &&
          old != null &&
          old.grant == value.grant &&
          (value.upload > old.upload || value.download > old.download);
      final start = value.start;
      final newFlow =
          old == null &&
          start != null &&
          !start.isAfter(now) &&
          now.difference(start) < window &&
          (value.upload > 0 || value.download > 0);
      if (delta || newFlow) _last[value.grant] = now;
    }
    _last.removeWhere(
      (_, timestamp) =>
          now.isBefore(timestamp) || now.difference(timestamp) >= window,
    );
    _previous = samples;
    _sampledAt = now;
  }

  bool online(String grant) => _last.containsKey(grant);

  RecipientPresence status(String grant) =>
      online(grant) ? RecipientPresence.online : RecipientPresence.offline;
}
