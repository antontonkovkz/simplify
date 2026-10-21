import '../l10n/l10n.dart';
import 'package:flutter/foundation.dart';

import '../domain/library_item.dart';
import '../domain/playlist_draft.dart';
import 'ports.dart';
import 'server_playlist_editor.dart';

/// One editor route owns one session. Source permissions/conflicts are shared
/// with queue saves, while draft state and save destinations stay independent.
class PlaylistEditSession extends ChangeNotifier {
  PlaylistEditSession({
    required this.source,
    required this.loadTracks,
    required this.server,
    required this.saveLocal,
    required this.serverSaved,
    required this.environment,
    required this.isCurrent,
    required this.isOffline,
  }) {
    environment.addListener(_environmentChanged);
    remote.addListener(_changed);
  }
  final LibraryItem source;
  final Future<List<LibraryItem>> Function() loadTracks;
  final ServerPlaylists? server;
  final Future<LibraryItem> Function(List<LibraryItem>, String) saveLocal;
  final Future<void> Function() serverSaved;
  final Listenable environment;
  final bool Function() isCurrent;
  final bool Function() isOffline;
  final remote = ServerPlaylistEditor();
  PlaylistDraft? draft;
  Object? error;
  bool loading = true;
  bool busy = false;
  bool expired = false;
  bool _disposed = false;
  int _loadGeneration = 0;
  AppMessage? _savedMessage;
  String? get savedMessage => _savedMessage?.text;
  set savedMessage(AppMessage? value) => _savedMessage = value;

  bool get canSaveServer =>
      !expired &&
      !loading &&
      !busy &&
      !isOffline() &&
      server != null &&
      remote.access != PlaylistEditAccess.checking &&
      remote.access != PlaylistEditAccess.denied &&
      draft != null &&
      !draft!.entries.any((e) => e.track.isLocal);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void _environmentChanged() {
    if (!isCurrent() && !expired) {
      expired = true;
      _loadGeneration++;
      remote.clear();
    }
    _changed();
  }

  void _ensureCurrent() {
    if (_disposed || expired || !isCurrent()) {
      throw const AppFailure(AppMessage.theAccountHasChangedOpenThePlaylist);
    }
  }

  void _ensureEditable() {
    _ensureCurrent();
    if (busy || loading || draft == null) {
      throw const AppFailure(AppMessage.waitForTheCurrentOperationToFinish);
    }
  }

  Future<void> initialize() async {
    if (busy) return;
    final generation = ++_loadGeneration;
    loading = true;
    error = null;
    _changed();
    try {
      _ensureCurrent();
      final tracks = await loadTracks();
      if (_disposed || generation != _loadGeneration) return;
      _ensureCurrent();
      draft = PlaylistDraft(tracks.where((t) => t.isTrack).toList());
      loading = false;
      await remote.open(
        isOffline() ? null : server,
        source,
        baseline: draft!.tracks.map((t) => t.id).toList(),
      );
    } catch (e) {
      if (!_disposed && generation == _loadGeneration) error = e;
    } finally {
      if (!_disposed && generation == _loadGeneration) {
        loading = false;
        _changed();
      }
    }
  }

  void append(List<LibraryItem> tracks) {
    _ensureEditable();
    draft!.append(tracks);
    savedMessage = null;
    _changed();
  }

  void remove(String id) {
    _ensureEditable();
    draft!.remove(id);
    savedMessage = null;
    _changed();
  }

  void move(int from, int to) {
    _ensureEditable();
    draft!.move(from, to);
    savedMessage = null;
    _changed();
  }

  Future<void> saveToServer({bool overwriteChanged = false}) async {
    _ensureEditable();
    if (isOffline() || server == null) {
      throw const AppFailure(AppMessage.connectToTheServerToSave);
    }
    final tracks = draft!.tracks;
    busy = true;
    _changed();
    try {
      await remote.save(
        server!,
        tracks,
        overwriteChanged: overwriteChanged,
        isCurrent: () => !_disposed && !expired && isCurrent(),
      );
      _ensureCurrent();
      draft!.markSaved();
      savedMessage = AppMessage.savedToServer;
      await serverSaved();
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<LibraryItem> saveAsLocal(String name) async {
    _ensureEditable();
    final tracks = draft!.tracks;
    busy = true;
    _changed();
    try {
      final item = await saveLocal(tracks, name);
      _ensureCurrent();
      draft!.markSaved();
      savedMessage = AppMessage.savedLocally(item.name);
      return item;
    } finally {
      busy = false;
      _changed();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _loadGeneration++;
    environment.removeListener(_environmentChanged);
    remote.removeListener(_changed);
    remote.dispose();
    super.dispose();
  }
}
