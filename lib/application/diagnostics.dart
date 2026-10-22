import 'dart:async';
import 'dart:collection';

/// Bounded, process-local diagnostics. Never retain exception messages, URLs,
/// headers, tokens or media paths, and never upload events automatically.
class Diagnostics {
  static final Queue<({DateTime time, String operation, String type})> _events =
      Queue();
  static List<({DateTime time, String operation, String type})> get events =>
      List.unmodifiable(_events);
  static void record(String operation, Object error) {
    if (_events.length == 50) _events.removeFirst();
    _events.add((
      time: DateTime.now().toUtc(),
      operation: operation,
      type: error.runtimeType.toString(),
    ));
  }

  static Future<void> guard(String operation, Future<void> future) async {
    try {
      await future;
    } on Object catch (error) {
      record(operation, error);
    }
  }
}
