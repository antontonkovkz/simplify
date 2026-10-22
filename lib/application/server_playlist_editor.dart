import '../l10n/l10n.dart';
import 'package:flutter/foundation.dart';

import '../domain/library_item.dart';
import 'ports.dart';

class ServerPlaylistConflict extends AppFailure {
  const ServerPlaylistConflict()
    : super(AppMessage.theServerPlaylistDiffersFromTheOriginal);
}

enum PlaylistEditAccess { checking, allowed, denied, unavailable }

/// Source provenance and explicit server saves, independent of audio and widgets.
class ServerPlaylistEditor extends ChangeNotifier {
  int revision = 0;
  @override
  void notifyListeners() {
    revision++;
    super.notifyListeners();
  }

  LibraryItem? item;
  PlaylistEditAccess access = PlaylistEditAccess.unavailable;
  bool saving = false;
  List<String>? _baseline;
  int _generation = 0;

  Map<String, dynamic>? toJson() =>
      item == null ? null : {'item': item!.toJson(), 'baseline': _baseline};

  void clear() {
    _generation++;
    item = null;
    _baseline = null;
    access = PlaylistEditAccess.unavailable;
    saving = false;
    notifyListeners();
  }

  Future<void> open(
    ServerPlaylists? library,
    LibraryItem playlist, {
    List<String>? baseline,
  }) async {
    final generation = ++_generation;
    item = playlist;
    _baseline = baseline == null ? null : List.of(baseline);
    saving = false;
    access = PlaylistEditAccess.checking;
    notifyListeners();
    if (library == null) {
      access = PlaylistEditAccess.unavailable;
      notifyListeners();
      return;
    }
    try {
      final allowed = await library.canEditPlaylist(playlist.id);
      if (generation != _generation) return;
      access = allowed ? PlaylistEditAccess.allowed : PlaylistEditAccess.denied;
    } on Object catch (_) {
      if (generation != _generation) return;
      access = PlaylistEditAccess.unavailable;
    }
    notifyListeners();
  }

  Future<void> refreshAccess(ServerPlaylists? library) async {
    final target = item;
    final generation = _generation;
    if (target == null || library == null || saving) return;
    try {
      final allowed = await library.canEditPlaylist(target.id);
      if (generation != _generation) return;
      access = allowed ? PlaylistEditAccess.allowed : PlaylistEditAccess.denied;
    } on Object catch (_) {
      if (generation != _generation) return;
      access = PlaylistEditAccess.unavailable;
    }
    notifyListeners();
  }

  Future<void> restore(
    ServerPlaylists? library,
    Map<String, dynamic>? data,
  ) async {
    if (data == null || data['item'] is! Map) {
      clear();
      return;
    }
    final candidates = decodeItems([data['item']]);
    if (candidates.isEmpty ||
        !candidates.first.isPlaylist ||
        candidates.first.isLocalPlaylist) {
      clear();
      return;
    }
    await open(
      library,
      candidates.first,
      baseline: data['baseline'] is List
          ? (data['baseline'] as List).whereType<String>().toList()
          : null,
    );
  }

  static String _normalizeId(String id) => id.replaceAll('-', '').toLowerCase();

  static bool sameIds(List<String> a, List<String> b) =>
      listEquals(a.map(_normalizeId).toList(), b.map(_normalizeId).toList());

  bool hasChanges(List<String> ids) =>
      _baseline != null && !sameIds(ids, _baseline!);

  Future<void> save(
    ServerPlaylists library,
    List<LibraryItem> tracks, {
    bool overwriteChanged = false,
    bool Function()? isCurrent,
  }) async {
    final target = item;
    if (target == null) {
      throw const AppFailure(AppMessage.noServerPlaylistIsOpen);
    }
    if (saving) {
      throw const AppFailure(AppMessage.thisPlaylistIsAlreadyBeingSaved);
    }
    if (tracks.any((track) => track.isLocal || !track.isTrack)) {
      throw const AppFailure(AppMessage.musicFromFilesCannotBeSavedTo);
    }
    final ids = tracks.map((track) => track.id).toList();
    final generation = _generation;
    saving = true;
    notifyListeners();
    try {
      // Always recheck permissions: they may have changed since opening.
      if (!await library.canEditPlaylist(target.id)) {
        if (generation == _generation) access = PlaylistEditAccess.denied;
        throw const AppFailure(
          AppMessage.youDoNotHavePermissionToEdit,
          status: 403,
        );
      }
      await library.validatePlaylistTracks(ids);
      final current = await library.playlistIds(target.id);
      if (!overwriteChanged &&
          (_baseline == null || !sameIds(current, _baseline!))) {
        throw const ServerPlaylistConflict();
      }
      // Changing the account/source while preflight requests run cancels writing.
      if (generation != _generation || !(isCurrent?.call() ?? true)) {
        throw const AppFailure(
          AppMessage.thePlaylistSourceChangedSavingWasCanceled,
        );
      }
      await library.replacePlaylist(target.id, ids);
      final saved = await library.playlistIds(target.id);
      if (!sameIds(saved, ids)) {
        throw const AppFailure(AppMessage.theSavedPlaylistDiffersFromYourList);
      }
      if (generation == _generation) {
        _baseline = ids;
        access = PlaylistEditAccess.allowed;
      }
    } on AppFailure catch (error) {
      if (generation == _generation && error.status == 403) {
        access = PlaylistEditAccess.denied;
      }
      rethrow;
    } finally {
      if (generation == _generation) {
        saving = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }
}
