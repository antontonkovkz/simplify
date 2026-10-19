import 'package:flutter/foundation.dart';

import '../domain/library_item.dart';
import 'ports.dart';

class ServerPlaylistConflict extends AppFailure {
  const ServerPlaylistConflict()
    : super(
        'Состав плейлиста на сервере отличается от исходного снимка очереди',
      );
}

enum PlaylistEditAccess { checking, allowed, denied, unavailable }

/// Queue provenance and explicit server saves, independent of audio and widgets.
class ServerPlaylistEditor extends ChangeNotifier {
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
    } catch (_) {
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
    } catch (_) {
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
    final playlist = LibraryItem.fromJson(
      Map<String, dynamic>.from(data['item']),
    );
    if (!playlist.isPlaylist || playlist.isLocalPlaylist) {
      clear();
      return;
    }
    await open(
      library,
      playlist,
      baseline: (data['baseline'] as List?)?.cast<String>(),
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
  }) async {
    final target = item;
    if (target == null) throw const AppFailure('Серверный плейлист не открыт');
    if (saving) throw const AppFailure('Плейлист уже сохраняется');
    if (tracks.any((track) => track.isLocal || !track.isTrack)) {
      throw const AppFailure(
        'Музыку из «Файлов» нельзя сохранить на сервер. Сохраните очередь как локальный плейлист.',
      );
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
          'Нет права редактировать этот плейлист',
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
      if (generation != _generation) {
        throw const AppFailure(
          'Источник очереди изменился. Сохранение отменено.',
        );
      }
      await library.replacePlaylist(target.id, ids);
      final saved = await library.playlistIds(target.id);
      if (!sameIds(saved, ids)) {
        throw const AppFailure(
          'Состав плейлиста на сервере отличается от очереди. Обновите библиотеку и проверьте плейлист.',
        );
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
