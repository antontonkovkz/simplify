import 'package:flutter/foundation.dart';
import '../domain/library_item.dart';
import '../l10n/l10n.dart';
import 'ports.dart';
import 'server_playlist_editor.dart';

/// A confirmed creation whose contents could not be verified. Never recreate it
/// automatically: the returned ID already identifies a server-side playlist.
class CreatedPlaylistUnverified extends AppFailure {
  CreatedPlaylistUnverified(this.item)
    : super(AppMessage.playlistCreatedCheckContents(item.name));
  final LibraryItem item;
}

/// Preflight and postconditions shared by server playlist creation workflows.
class PlaylistMutations {
  bool busy = false;

  Future<LibraryItem> create(
    ManagedPlaylists library,
    String name,
    List<LibraryItem> tracks, {
    required bool Function() isCurrent,
  }) async {
    if (busy) {
      throw const AppFailure(AppMessage.waitForTheCurrentOperationToFinish);
    }
    final title = name.trim();
    if (title.isEmpty) throw const AppFailure(AppMessage.enterAPlaylistName);
    if (tracks.isEmpty) throw const AppFailure(AppMessage.theQueueIsEmpty);
    if (tracks.any((t) => !t.isTrack || t.isLocal)) {
      throw const AppFailure(AppMessage.musicFromFilesCannotBeSavedTo);
    }
    final ids = tracks.map((t) => t.id).toList();
    busy = true;
    try {
      await library.validatePlaylistTracks(ids);
      if (!isCurrent()) throw const AppFailure(AppMessage.theAccountHasChanged);
      final item = await library.createPlaylist(
        title,
        ids,
        isCurrent: isCurrent,
      );
      try {
        if (!ServerPlaylistEditor.sameIds(
          await library.playlistIds(item.id),
          ids,
        )) {
          throw const AppFailure(
            AppMessage.theSavedPlaylistDiffersFromYourList,
          );
        }
      } catch (_) {
        throw CreatedPlaylistUnverified(item);
      }
      return item;
    } finally {
      busy = false;
    }
  }
}

/// Selection and partial batch results, independent of widgets and transport.
class PlaylistDeletion extends ChangeNotifier {
  PlaylistDeletion({
    required this.remove,
    required this.isCurrent,
    required LibraryItem initial,
  }) {
    selected[initial.id] = initial;
  }
  final Future<void> Function(LibraryItem) remove;
  final bool Function() isCurrent;
  final Map<String, LibraryItem> selected = {};
  final Map<String, Object> errors = {};
  final Set<String> deleted = {};
  bool deleting = false;
  int completed = 0;
  int total = 0;
  bool _disposed = false;

  void toggle(LibraryItem item) {
    if (deleting || !item.isPlaylist || !isCurrent()) return;
    if (selected.remove(item.id) == null) selected[item.id] = item;
    errors.remove(item.id);
    notifyListeners();
  }

  Future<void> deleteSelected() async {
    if (deleting || selected.isEmpty || !isCurrent()) return;
    final snapshot = selected.values.toList();
    deleting = true;
    completed = 0;
    total = snapshot.length;
    errors.clear();
    notifyListeners();
    try {
      for (final item in snapshot) {
        if (_disposed || !isCurrent()) break;
        try {
          if (!item.isPlaylist) {
            throw const AppFailure(AppMessage.onlyPlaylistsCanBeDeleted);
          }
          await remove(item);
          deleted.add(item.id);
          selected.remove(item.id);
        } catch (error) {
          errors[item.id] = error;
        }
        completed++;
        if (!_disposed) notifyListeners();
      }
    } finally {
      deleting = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
