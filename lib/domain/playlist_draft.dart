import 'library_item.dart';

class PlaylistDraftEntry {
  const PlaylistDraftEntry(this.id, this.track);
  final String id;
  final LibraryItem track;
}

/// An independent ordered draft, never a playback queue. Occurrences have their
/// own identity so removing/reordering one repeated song preserves the others.
class PlaylistDraft {
  PlaylistDraft(List<LibraryItem> tracks) {
    append(tracks);
    markSaved();
  }
  final List<PlaylistDraftEntry> _entries = [];
  List<PlaylistDraftEntry>? _snapshot;
  List<String> _savedIds = [];
  int _serial = 0;
  List<PlaylistDraftEntry> get entries =>
      _snapshot ??= List.unmodifiable(_entries);
  List<LibraryItem> get tracks => _entries.map((e) => e.track).toList();
  bool get hasChanges {
    if (_entries.length != _savedIds.length) return true;
    for (var i = 0; i < _entries.length; i++) {
      if (_entries[i].track.id != _savedIds[i]) return true;
    }
    return false;
  }

  void markSaved() => _savedIds = _entries.map((e) => e.track.id).toList();
  void append(List<LibraryItem> tracks) {
    if (tracks.any((e) => !e.isTrack)) {
      throw ArgumentError('Only audio tracks can be added to a playlist');
    }
    _entries.addAll(
      tracks.map((t) => PlaylistDraftEntry('draft:${_serial++}', t)),
    );
    _snapshot = null;
  }

  void remove(String id) {
    _entries.removeWhere((e) => e.id == id);
    _snapshot = null;
  }

  void move(int from, int to) {
    if (from < 0 || from >= _entries.length || to < 0 || to > _entries.length) {
      return;
    }
    if (to > from) to--;
    _entries.insert(to, _entries.removeAt(from));
    _snapshot = null;
  }
}
