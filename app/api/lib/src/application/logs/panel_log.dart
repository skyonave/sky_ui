import 'dart:async';
import 'dart:collection';

import 'package:sky_ui_shared/sky_ui_shared.dart';

class PanelLog {
  final _entries = Queue<CoreLogEntry>();
  final _operation = Object();
  int _sequence = 0;

  List<CoreLogEntry> entries() => List.unmodifiable(_entries);
  void clear() => _entries.clear();

  Future<T> operation<T>(String name, Future<T> Function() action) {
    final id = ++_sequence;
    return runZoned(() {
      event('$name started');
      return action();
    }, zoneValues: {_operation: id});
  }

  // Accept only application-defined messages and identifiers, never request
  // values, raw exceptions, native configuration, or credential material.
  void event(String message, {String level = 'info'}) {
    final operation = Zone.current[_operation];
    if (_entries.length == 300) _entries.removeFirst();
    _entries.add(
      CoreLogEntry(
        time: DateTime.now().toUtc(),
        level: level,
        message: operation == null ? message : '#$operation $message',
        source: 'sky-ui',
      ),
    );
  }
}
