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
  Object? _planSignature;
  int revision = 0;
  int _orderRevision = 0;
  static const maxHistory = 1000;

  bool shuffled = false;
  RepeatMode repeat = RepeatMode.off;

  List<QueueEntry>? _snapshot;
  Map<String, int>? _indices;
  Duration? _duration;
  bool _durationComputed = false;
  bool _allServerTracks = false;

  bool get allServerTracks {
    totalDuration;
    return _allServerTracks;
  }

  /// Unknown durations keep the total unknown; playback changes reuse it.
  Duration? get totalDuration {
    if (_durationComputed) return _duration;
    _durationComputed = true;
    if (_entries.isEmpty) return null;
    var milliseconds = 0;
    var known = true;
    _allServerTracks = true;
    for (final entry in _entries) {
      if (entry.track.durationMs <= 0) known = false;
      if (entry.track.isLocal) _allServerTracks = false;
      milliseconds += entry.track.durationMs;
    }
    return _duration = known ? Duration(milliseconds: milliseconds) : null;
  }

  /// Immutable snapshots remain valid after edits and are reused during scroll.
  List<QueueEntry> get entries => _snapshot ??= List.unmodifiable(_entries);
  int indexOfEntry(String? id) {
    if (id == null) return -1;
    final indices = _indices ??= {
      for (var i = 0; i < _entries.length; i++) _entries[i].id: i,
    };
    return indices[id] ?? -1;
  }

  int get currentIndex => indexOfEntry(_current?.id);
  void _invalidateEntries() {
    revision++;
    _orderRevision++;
    _durationComputed = false;
    _allServerTracks = false;
    _duration = null;
    _snapshot = null;
    _indices = null;
  }

  QueueEntry? get current => _current;

  /// A logical viewport anchor exists even while no queue screen is mounted.
  /// It derives from the persisted occurrence, so duplicate songs stay distinct.
  String? get viewAnchorId {
    if (_entries.isEmpty) return null;
    if (currentIndex >= 0) return _current!.id;
    return _entries[_detachedNextIndex.clamp(0, _entries.length - 1)].id;
  }

  bool get detached => _current != null && currentIndex < 0;
  bool get canPrevious =>
      (!shuffled && currentIndex > 0) ||
      (shuffled &&
          _historyIndex > 0 &&
          _history.take(_historyIndex).any((id) => indexOfEntry(id) >= 0));

  QueueEntry _entry(LibraryItem track) => QueueEntry(
    '${DateTime.now().microsecondsSinceEpoch}-${_serial++}',
    track,
  );

  void replace(
    List<LibraryItem> tracks, {
    int start = 0,
    bool randomStart = false,
  }) {
    _entries
      ..clear()
      ..addAll(tracks.map(_entry));
    _invalidateEntries();
    _history.clear();
    _visited.clear();
    _historyIndex = -1;
    _current = null;
    if (_entries.isNotEmpty) {
      final index = randomStart && shuffled
          ? _random.nextInt(_entries.length)
          : start.clamp(0, _entries.length - 1);
      select(_entries[index].id);
    }
  }

  void append(List<LibraryItem> tracks) {
    _entries.addAll(tracks.map(_entry));
    _invalidateEntries();
  }

  QueueEntry? select(String id) {
    final index = indexOfEntry(id);
    if (index == -1) return null;
    return _activate(_entries[index]);
  }

  QueueEntry _activate(QueueEntry entry) {
    if (_historyIndex + 1 < _history.length) {
      _history.removeRange(_historyIndex + 1, _history.length);
    }
    revision++;
    _current = entry;
    _history.add(entry.id);
    if (_history.length > maxHistory) {
      _history.removeRange(0, _history.length - maxHistory);
    }
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
      final index = indexOfEntry(id);
      if (index != -1) {
        revision++;
        return _current = _entries[index];
      }
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
    final index = detached ? _detachedNextIndex : currentIndex + 1;
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
      final index = detached ? _detachedNextIndex : currentIndex + 1;
      return index < _entries.length
          ? _entries[index]
          : repeat == RepeatMode.all
          ? _entries.first
          : null;
    }
    for (var i = _historyIndex + 1; i < _history.length; i++) {
      final index = indexOfEntry(_history[i]);
      if (index >= 0) return _entries[index];
    }
    final signature = (
      _orderRevision,
      _current?.id,
      _historyIndex,
      repeat,
      shuffled,
    );
    if (_planSignature == signature && _plannedId != null) {
      final index = indexOfEntry(_plannedId);
      if (index >= 0) return _entries[index];
    }
    var available = _entries.where((e) => !_visited.contains(e.id)).toList();
    if (available.isEmpty && repeat == RepeatMode.all) {
      available = _entries.where((e) => e.id != _current?.id).toList();
      if (available.isEmpty) available = List.of(_entries);
    }
    if (available.isEmpty) return null;
    if (_planSignature != signature ||
        !available.any((e) => e.id == _plannedId)) {
      _plannedId = available[_random.nextInt(available.length)].id;
      _planSignature = signature;
    }
    return available.firstWhere((e) => e.id == _plannedId);
  }

  QueueEntry? previous() {
    if (!shuffled) {
      final index = currentIndex;
      if (index > 0) return _activate(_entries[index - 1]);
      return null;
    }
    while (_historyIndex > 0) {
      final id = _history[--_historyIndex];
      final index = indexOfEntry(id);
      if (index != -1) {
        revision++;
        return _current = _entries[index];
      }
    }
    return null;
  }

  /// [newIndex] is an insertion boundary before removal (Flutter legacy API).
  /// Moving down one row therefore uses oldIndex + 2; moving up uses -1.
  void move(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final entry = _entries.removeAt(oldIndex);
    _entries.insert(newIndex, entry);
    _invalidateEntries();
  }

  /// Returns true when the removed entry was playing. The caller decides
  /// whether to leave the detached audio playing or advance immediately.
  bool remove(String id) {
    final index = indexOfEntry(id);
    if (index < 0) return false;
    final active = _current?.id == id;
    if (active) _detachedNextIndex = index;
    if (detached && index < _detachedNextIndex) _detachedNextIndex--;
    _entries.removeAt(index);
    _invalidateEntries();
    return active;
  }

  QueueSnapshot capture() => QueueSnapshot(
    entries,
    _current,
    shuffled,
    repeat,
    List<String>.unmodifiable(_history),
    _historyIndex,
    Set<String>.unmodifiable(_visited),
    _detachedNextIndex,
  );
  Map<String, dynamic> toJson() => capture().toJson();

  void restore(Map<String, dynamic> json) {
    QueueEntry? decode(Object? raw) {
      try {
        if (raw is! Map) return null;
        final entry = QueueEntry.fromJson(Map<String, dynamic>.from(raw));
        return entry.id.isEmpty || !entry.track.isTrack ? null : entry;
      } on FormatException {
        return null;
      } on TypeError {
        return null;
      } on ArgumentError {
        return null;
      }
    }

    _entries.clear();
    final ids = <String>{};
    for (final raw
        in json['entries'] is List ? json['entries'] as List : const []) {
      final entry = decode(raw);
      if (entry != null && ids.add(entry.id)) _entries.add(entry);
    }
    _invalidateEntries();
    _current = decode(json['current']);
    if (_current != null && indexOfEntry(_current!.id) >= 0) {
      _current = _entries[indexOfEntry(_current!.id)];
    }
    shuffled = json['shuffled'] == true;
    repeat =
        RepeatMode.values
            .where((mode) => mode.name == json['repeat'])
            .firstOrNull ??
        RepeatMode.off;
    final history =
        (json['history'] is List ? json['history'] as List : const [])
            .whereType<String>()
            .where((id) => id.isNotEmpty)
            .toList();
    final originalIndex = json['historyIndex'] is int
        ? json['historyIndex'] as int
        : -1;
    final removed = (history.length - maxHistory).clamp(0, history.length);
    _history
      ..clear()
      ..addAll(history.skip(removed));
    _historyIndex = (originalIndex - removed).clamp(-1, _history.length - 1);
    _visited
      ..clear()
      ..addAll(
        (json['visited'] is List ? json['visited'] as List : const [])
            .whereType<String>()
            .where((id) => ids.contains(id) || id == _current?.id),
      );
    _detachedNextIndex =
        (json['detachedNextIndex'] is int
                ? json['detachedNextIndex'] as int
                : 0)
            .clamp(0, _entries.length);
    _plannedId = null;
    _planSignature = null;
  }
}

/// Detached domain snapshot. LocalStore serializes this on its worker isolate,
/// so capturing a large queue never builds thousands of metadata maps in UI.
class QueueSnapshot {
  const QueueSnapshot(
    this.entries,
    this.current,
    this.shuffled,
    this.repeat,
    this.history,
    this.historyIndex,
    this.visited,
    this.detachedNextIndex,
  );
  final List<QueueEntry> entries;
  final QueueEntry? current;
  final bool shuffled;
  final RepeatMode repeat;
  final List<String> history;
  final int historyIndex;
  final Set<String> visited;
  final int detachedNextIndex;
  Map<String, dynamic> toJson() => {
    'entries': entries.map((e) => e.toJson()).toList(),
    'current': current?.toJson(),
    'shuffled': shuffled,
    'repeat': repeat.name,
    'history': history,
    'historyIndex': historyIndex,
    'visited': visited.toList(),
    'detachedNextIndex': detachedNextIndex,
  };
}
