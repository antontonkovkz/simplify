import 'dart:math';

import 'library_item.dart';

enum RepeatMode { off, all, one }

class QueueEntry {
  const QueueEntry(this.id, this.track);
  final String id;
  final LibraryItem track;
  Map<String, dynamic> toJson() => {'id': id, 'track': track.toJson()};
  factory QueueEntry.fromJson(Map<String, dynamic> json) => QueueEntry(
    json['id'] as String,
    LibraryItem.fromJson(Map<String, dynamic>.from(json['track'] as Map)),
  );
}

/// Pure playback order. The audio engine and widgets never own another queue.
class QueueEngine {
  QueueEngine({Random? random}) : _random = random ?? Random();
  final Random _random;
  final List<QueueEntry> _entries = [];
  final List<String> _history = [];
  final Set<String> _visited = {};
  int _historyIndex = -1;
  int _serial = 0;
  int _detachedNextIndex = 0;
  QueueEntry? _current;
  String? _plannedId;
  String? _planSignature;
  bool shuffled = false;
  RepeatMode repeat = RepeatMode.off;

  List<QueueEntry> get entries => List.unmodifiable(_entries);
  QueueEntry? get current => _current;
  bool get detached =>
      _current != null && !_entries.any((e) => e.id == _current!.id);
  bool get canPrevious =>
      (!shuffled && _entries.indexWhere((e) => e.id == _current?.id) > 0) ||
      (shuffled &&
          _historyIndex > 0 &&
          _history
              .take(_historyIndex)
              .any((id) => _entries.any((e) => e.id == id)));

  QueueEntry _entry(LibraryItem track) => QueueEntry(
    '${DateTime.now().microsecondsSinceEpoch}-${_serial++}',
    track,
  );

  void replace(List<LibraryItem> tracks, {int start = 0}) {
    _entries
      ..clear()
      ..addAll(tracks.map(_entry));
    _history.clear();
    _visited.clear();
    _historyIndex = -1;
    _current = null;
    if (_entries.isNotEmpty) {
      select(_entries[start.clamp(0, _entries.length - 1)].id);
    }
  }

  void append(List<LibraryItem> tracks) => _entries.addAll(tracks.map(_entry));

  QueueEntry? select(String id) {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index == -1) return null;
    return _activate(_entries[index]);
  }

  QueueEntry _activate(QueueEntry entry) {
    if (_historyIndex + 1 < _history.length) {
      _history.removeRange(_historyIndex + 1, _history.length);
    }
    _current = entry;
    _history.add(entry.id);
    _historyIndex = _history.length - 1;
    _visited.add(entry.id);
    return entry;
  }

  QueueEntry? next({bool automatic = false}) {
    if (_entries.isEmpty) return null;
    if (automatic &&
        repeat == RepeatMode.one &&
        _current != null &&
        !detached) {
      return _current;
    }
    while (shuffled && _historyIndex + 1 < _history.length) {
      final id = _history[++_historyIndex];
      final index = _entries.indexWhere((e) => e.id == id);
      if (index != -1) return _current = _entries[index];
    }
    if (shuffled) {
      final planned = previewNext(automatic: automatic);
      var available = _entries.where((e) => !_visited.contains(e.id)).toList();
      if (available.isEmpty && repeat == RepeatMode.all) {
        _visited.clear();
        available = _entries.where((e) => e.id != _current?.id).toList();
        if (available.isEmpty) available = List.of(_entries);
      }
      return available.isEmpty
          ? null
          : _activate(planned ?? available[_random.nextInt(available.length)]);
    }
    final index = detached
        ? _detachedNextIndex
        : _entries.indexWhere((e) => e.id == _current?.id) + 1;
    if (index < _entries.length) return _activate(_entries[index]);
    if (repeat == RepeatMode.all) return _activate(_entries.first);
    return null;
  }

  /// Reserves a random successor without changing playback/history. Prefetch
  /// and the actual transition use the same occurrence, even with duplicates.
  QueueEntry? previewNext({bool automatic = true}) {
    if (_entries.isEmpty) return null;
    if (automatic &&
        repeat == RepeatMode.one &&
        _current != null &&
        !detached) {
      return _current;
    }
    if (!shuffled) {
      final index = detached
          ? _detachedNextIndex
          : _entries.indexWhere((e) => e.id == _current?.id) + 1;
      return index < _entries.length
          ? _entries[index]
          : repeat == RepeatMode.all
          ? _entries.first
          : null;
    }
    for (var i = _historyIndex + 1; i < _history.length; i++) {
      for (final entry in _entries) {
        if (entry.id == _history[i]) return entry;
      }
    }
    var available = _entries.where((e) => !_visited.contains(e.id)).toList();
    if (available.isEmpty && repeat == RepeatMode.all) {
      available = _entries.where((e) => e.id != _current?.id).toList();
      if (available.isEmpty) available = List.of(_entries);
    }
    if (available.isEmpty) return null;
    final signature =
        '${_current?.id}|$_historyIndex|${repeat.name}|'
        '${available.map((e) => e.id).join(',')}';
    if (_planSignature != signature ||
        !available.any((e) => e.id == _plannedId)) {
      _plannedId = available[_random.nextInt(available.length)].id;
      _planSignature = signature;
    }
    return available.firstWhere((e) => e.id == _plannedId);
  }

  QueueEntry? previous() {
    if (!shuffled) {
      final index = _entries.indexWhere((e) => e.id == _current?.id);
      if (index > 0) return _activate(_entries[index - 1]);
      return null;
    }
    while (_historyIndex > 0) {
      final id = _history[--_historyIndex];
      final index = _entries.indexWhere((e) => e.id == id);
      if (index != -1) return _current = _entries[index];
    }
    return null;
  }

  void move(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final entry = _entries.removeAt(oldIndex);
    _entries.insert(newIndex, entry);
  }

  /// Returns true when the removed entry was playing. The caller decides
  /// whether to leave the detached audio playing or advance immediately.
  bool remove(String id) {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return false;
    final active = _current?.id == id;
    if (active) _detachedNextIndex = index;
    if (detached && index < _detachedNextIndex) _detachedNextIndex--;
    _entries.removeAt(index);
    return active;
  }

  Map<String, dynamic> toJson() => {
    'entries': _entries.map((e) => e.toJson()).toList(),
    'current': _current?.toJson(),
    'shuffled': shuffled,
    'repeat': repeat.name,
    'history': _history,
    'historyIndex': _historyIndex,
    'visited': _visited.toList(),
    'detachedNextIndex': _detachedNextIndex,
  };

  void restore(Map<String, dynamic> json) {
    _entries
      ..clear()
      ..addAll(
        (json['entries'] as List? ?? []).map(
          (e) => QueueEntry.fromJson(Map<String, dynamic>.from(e as Map)),
        ),
      );
    _current = json['current'] == null
        ? null
        : QueueEntry.fromJson(
            Map<String, dynamic>.from(json['current'] as Map),
          );
    shuffled = json['shuffled'] as bool? ?? false;
    repeat = RepeatMode.values.byName(json['repeat'] as String? ?? 'off');
    _history
      ..clear()
      ..addAll((json['history'] as List? ?? []).cast<String>());
    _historyIndex = (json['historyIndex'] as int? ?? -1).clamp(
      -1,
      _history.length - 1,
    );
    _visited
      ..clear()
      ..addAll((json['visited'] as List? ?? []).cast<String>());
    _detachedNextIndex = json['detachedNextIndex'] as int? ?? 0;
  }
}
