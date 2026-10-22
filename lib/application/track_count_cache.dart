import 'dart:async';

/// Coalesces visible-row requests and keeps last known totals across refreshes.
class TrackCountCache {
  TrackCountCache({Map<String, int> initial = const {}, this.onChanged})
    : _values = Map.of(initial);
  final void Function(Map<String, int>)? onChanged;
  final Map<String, int> _values;
  final Set<String> _fresh = {};
  final Map<String, Future<int?>> _pending = {};
  final List<Completer<void>> _waiting = [];
  int _active = 0;
  int _generation = 0;
  bool _closed = false;

  int? peek(String id) => _values[id];

  Future<int?> resolve(String id, Future<int> Function() fetch) {
    if (_closed || _fresh.contains(id)) return Future.value(_values[id]);
    if (_pending[id] case final existing?) return existing;
    final generation = _generation;
    late final Future<int?> job;
    job = _load(id, fetch, generation).whenComplete(() {
      if (identical(_pending[id], job)) _pending.remove(id);
    });
    _pending[id] = job;
    return job;
  }

  Future<void> _acquire() async {
    if (_active < 3) {
      _active++;
      return;
    }
    final permit = Completer<void>();
    _waiting.add(permit);
    await permit.future;
  }

  void _release() {
    if (_waiting.isEmpty) {
      _active--;
    } else {
      _waiting.removeAt(0).complete();
    }
  }

  Future<int?> _load(
    String id,
    Future<int> Function() fetch,
    int generation,
  ) async {
    await _acquire();
    try {
      if (_closed || generation != _generation) return _values[id];
      final count = await fetch();
      if (!_closed && generation == _generation && count >= 0) {
        _values[id] = count;
        _fresh.add(id);
        onChanged?.call(Map.of(_values));
      }
    } on Object catch (_) {
      // Unknown stays unknown; an unavailable server must not turn into zero.
    } finally {
      _release();
    }
    return _values[id];
  }

  void invalidate() {
    _generation++;
    _fresh.clear();
    _pending.clear();
  }

  void dispose() {
    _closed = true;
    invalidate();
  }
}
