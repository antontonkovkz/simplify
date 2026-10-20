import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../domain/download_group.dart';
import '../domain/offline_availability.dart';
import '../domain/library_item.dart';
import '../domain/volume_normalization.dart';
import '../domain/library_search.dart';
import '../domain/queue_engine.dart';
import '../domain/browse_location.dart';
import '../infrastructure/download_manager.dart';
import '../infrastructure/device_network_monitor.dart';
import '../infrastructure/jellyfin_library.dart';
import '../infrastructure/local_store.dart';
import '../infrastructure/local_playlists.dart';
import '../infrastructure/music_audio_handler.dart';
import '../infrastructure/local_music_library.dart';
import '../infrastructure/track_preloader.dart';
import 'ports.dart';
import 'track_count_cache.dart';
import 'playlist_edit_session.dart';
import 'server_playlist_editor.dart';

class AppController extends ChangeNotifier {
  AppController(this.store, this.audio, {NetworkMonitor? network})
    : network = network ?? DeviceNetworkMonitor() {
    serverPlaylist.addListener(_serverPlaylistChanged);
  }
  final NetworkMonitor network;
  final LocalStore store;
  final MusicAudioHandler audio;
  final queue = QueueEngine();
  final messages = StreamController<String>.broadcast();
  final notifications = FlutterLocalNotificationsPlugin();
  JellyfinLibrary? library;
  DownloadManager? downloads;
  late final localMusic = LocalMusicLibrary(store);
  late final localPlaylists = LocalPlaylists(store);
  final serverPlaylist = ServerPlaylistEditor();
  int serverPlaylistRevision = 0;
  void _serverPlaylistChanged() => notifyListeners();
  String? loadedLocalPlaylistId;
  LibraryItem? get loadedLocalPlaylist =>
      localPlaylists.item(loadedLocalPlaylistId);
  bool get queueHasChanges {
    final ids = queue.entries.map((entry) => entry.track.id).toList();
    if (serverPlaylist.item != null) return serverPlaylist.hasChanges(ids);
    final local = loadedLocalPlaylist;
    return local != null &&
        !listEquals(
          ids,
          localPlaylists.tracks(local.id).map((t) => t.id).toList(),
        );
  }

  TrackPreloader? preloader;
  BrowseLocation browse = const BrowseLocation();
  bool importing = false;
  int localRevision = 0;
  int countRevision = 0;
  TrackCountCache _trackCounts = TrackCountCache();
  String _deviceId = 'simplefy-ios';
  final Map<String, List<LibraryItem>> _cache = {};
  List<DownloadChange> pendingChanges = [];
  bool initialized = false;
  bool _sessionReady = false;
  bool _persistenceErrorShown = false;
  bool refreshing = false;
  VolumeNormalizationMode normalizationMode = VolumeNormalizationMode.track;
  bool allowMobileStreaming = true;
  bool allowMobileDownloads = true;
  bool onlyDownloaded = false;
  bool waitingForNetwork = false;
  bool wantsPlayback = false;
  String? status;
  String? _loadedEntry;
  bool _loadedFromFile = false;
  String? _convertedSession;
  String? _lastFailureEntry;
  int _failurePosition = 0;
  int _recoveryAttempts = 0;
  int _operation = 0;
  int _groupPlayRequest = 0;
  int _skipCount = 0;
  int _restoredPosition = 0;
  DateTime _lastSave = DateTime(2000);
  NetworkKind _connection = NetworkKind.other;
  StreamSubscription<NetworkKind>? _networkSubscription;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  Timer? _retryTimer;

  bool get loggedIn => library != null && _sessionReady;
  bool get hasLibrary =>
      loggedIn || !localMusic.isEmpty || localPlaylists.items.isNotEmpty;
  String get libraryIdentity => loggedIn
      ? '${library!.session.server}|${library!.session.userId}'
      : 'local';
  bool get isPlaying => audio.player.playing;
  bool get hasLoadedCurrent =>
      _loadedEntry != null && _loadedEntry == queue.current?.id;
  Duration get position => hasLoadedCurrent
      ? audio.player.position
      : Duration(milliseconds: _restoredPosition);
  bool get offline => _connection == NetworkKind.offline;
  bool get _streamAllowed =>
      !offline &&
      (allowMobileStreaming || _connection == NetworkKind.unmetered);
  String get _account => downloads!.namespace;
  String get _stateKey =>
      loggedIn || downloads != null ? 'state_$_account' : 'state_local';
  String get _catalogKey => 'catalog_$_account';

  Future<void> initialize({String bootstrapSession = ''}) async {
    await localMusic.initialize();
    _deviceId = await store.installationId();
    await notifications.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_music'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
    _connection = await network.current();
    _networkSubscription = network.changes.listen((value) async {
      _connection = value;
      _refreshPreload();
      if (!_streamAllowed &&
          isPlaying &&
          queue.current != null &&
          !_loadedFromFile) {
        _restoredPosition = audio.player.position.inMilliseconds;
        waitingForNetwork = true;
        await audio.player.pause();
      } else if (_streamAllowed && waitingForNetwork && wantsPlayback) {
        unawaited(resume());
      }
      notifyListeners();
    });
    audio
      ..onPlay = resume
      ..onPause = pause
      ..onStop = stop
      ..onNext = next
      ..onPrevious = previous
      ..onSelect = selectIndex
      ..onSeek = seek
      ..onShuffle = setShuffle
      ..onRepeat = setRepeat
      ..onError = _playbackError;
    _playingSubscription = audio.player.playingStream.listen(
      (_) => notifyListeners(),
    );
    _positionSubscription = audio.player.positionStream.listen((_) {
      if (DateTime.now().difference(_lastSave).inSeconds >= 5 && hasLibrary) {
        _lastSave = DateTime.now();
        unawaited(save());
      }
    });
    var raw = await store.readSession();
    var usingBootstrap = false;
    if (raw == null && bootstrapSession.isNotEmpty) {
      final installation = await store.read('installation');
      if (installation['bootstrapApplied'] != true) {
        raw = bootstrapSession;
        usingBootstrap = true;
      }
    }
    if (raw != null) {
      try {
        await _attach(
          ServerSession.fromJson(jsonDecode(raw) as Map<String, dynamic>),
        );
        if (usingBootstrap) {
          await store.saveSession(raw);
          final installation = await store.read('installation');
          await store.write('installation', {
            ...installation,
            'bootstrapApplied': true,
          });
        }
      } catch (_) {
        status = 'Не удалось восстановить подключение. Войдите ещё раз.';
      }
    }
    if (!loggedIn) await _restoreState(await store.read(_stateKey));
    initialized = true;
    notifyListeners();
    if (loggedIn) unawaited(refresh());
  }

  Future<void> login(String server, String username, String password) async {
    final session = await JellyfinLibrary.login(
      server,
      username,
      password,
      deviceId: _deviceId,
    );
    if (hasLibrary) await stop();
    await store.saveSession(jsonEncode(session.toJson()));
    await _attach(session);
    notifyListeners();
    unawaited(refresh());
  }

  Future<void> _attach(ServerSession session) async {
    _sessionReady = false;
    _operation++;
    _loadedEntry = null;
    wantsPlayback = false;
    waitingForNetwork = false;
    refreshing = false;
    pendingChanges = [];
    library?.close();
    downloads?.dispose();
    preloader?.dispose();
    library = JellyfinLibrary(session, deviceId: _deviceId);
    downloads = DownloadManager(store, library!);
    final cache = Directory(
      '${store.directory.parent.path}/Caches/simplefy-prefetch/$_account',
    );
    // A previous process may have left partial speculative files. They are
    // disposable and are never treated as offline downloads.
    if (await cache.exists()) await cache.delete(recursive: true);
    preloader = TrackPreloader(cache, library!);
    final state = await store.read(_stateKey);
    await _restoreState(state);
    downloads!.allowCellular = allowMobileDownloads;
    await downloads!.initialize();
    downloads!.addListener(notifyListeners);
    final saved = await store.read(_catalogKey);
    _cache.clear();
    for (final e in saved.entries) {
      _cache[e.key] = decodeItems(e.value);
    }
    audio.publishQueue(
      queue,
      position: Duration(milliseconds: _restoredPosition),
    );
    _sessionReady = true;
  }

  Future<void> _restoreState(Map<String, dynamic> state) async {
    _trackCounts.dispose();
    final countKey = 'track_counts_$_stateKey';
    final savedCounts = await store.read(countKey);
    _trackCounts = TrackCountCache(
      initial: {
        for (final e in (savedCounts['counts'] as Map? ?? {}).entries)
          if (e.key is String && e.value is num && e.value >= 0)
            e.key as String: (e.value as num).toInt(),
      },
      onChanged: (values) => unawaited(_persist(countKey, {'counts': values})),
    );
    countRevision++;
    await localPlaylists.load(_stateKey);
    loadedLocalPlaylistId = state['localPlaylistId'] as String?;
    if (loadedLocalPlaylist == null) loadedLocalPlaylistId = null;
    unawaited(
      serverPlaylist.restore(
        library,
        (state['serverPlaylist'] as Map?)?.cast<String, dynamic>(),
      ),
    );
    normalizationMode = VolumeNormalizationMode.restore(
      state['volumeNormalization'],
    );
    allowMobileStreaming = state['mobileStreaming'] as bool? ?? true;
    allowMobileDownloads = state['mobileDownloads'] as bool? ?? true;
    onlyDownloaded = state['onlyDownloaded'] as bool? ?? false;
    queue.restore(Map<String, dynamic>.from(state['queue'] as Map? ?? {}));
    _restoredPosition = state['position'] as int? ?? 0;
    browse = BrowseLocation.fromJson(
      Map<String, dynamic>.from(state['browse'] as Map? ?? {}),
    );
    audio.publishQueue(
      queue,
      position: Duration(milliseconds: _restoredPosition),
    );
  }

  Future<void> logout() async {
    await stop();
    await save();
    _operation++;
    await store.deleteSession();
    downloads?.dispose();
    preloader?.dispose();
    preloader = null;
    downloads = null;
    library?.close();
    library = null;
    _sessionReady = false;
    _cache.clear();
    pendingChanges = [];
    queue.replace([]);
    browse = const BrowseLocation();
    _loadedEntry = null;
    await _restoreState(await store.read(_stateKey));
    notifyListeners();
  }

  Future<void> save() async {
    if (!initialized && !loggedIn) return;
    if (downloads != null && !_sessionReady) return;
    await _persist(_stateKey, {
      'queue': queue.toJson(),
      'localPlaylistId': loadedLocalPlaylistId,
      'serverPlaylist': serverPlaylist.toJson(),
      'position': _loadedEntry == queue.current?.id
          ? audio.player.position.inMilliseconds
          : _restoredPosition,
      'volumeNormalization': normalizationMode.name,
      'mobileStreaming': allowMobileStreaming,
      'mobileDownloads': allowMobileDownloads,
      'onlyDownloaded': onlyDownloaded,
      'browse': browse.toJson(),
    });
  }

  Future<void> _saveCatalog() => _persist(
    _catalogKey,
    _cache.map(
      (key, value) => MapEntry(key, value.map((e) => e.toJson()).toList()),
    ),
  );

  Future<void> _persist(String key, Map<String, dynamic> data) async {
    try {
      await store.write(key, data);
      _persistenceErrorShown = false;
    } catch (_) {
      if (!_persistenceErrorShown) {
        _persistenceErrorShown = true;
        message(
          'Не удалось сохранить состояние. Проверьте свободное место на устройстве.',
        );
      }
    }
  }

  Future<void> refresh() async {
    unawaited(serverPlaylist.refreshAccess(library));
    if (refreshing || !loggedIn) return;
    final api = library!;
    final manager = downloads!;
    refreshing = true;
    notifyListeners();
    try {
      final collections = await api.collections();
      final playlists = await api.playlists();
      final changes = await manager.changes();
      if (!identical(api, library)) return;
      _cache['collections'] = collections;
      _cache['playlists'] = playlists;
      _trackCounts.invalidate();
      countRevision++;
      // Keep visited ancestry for offline navigation. Online pages always fetch
      // fresh children, so retaining their last successful snapshot is safe.
      pendingChanges = changes;
      await _saveCatalog();
      status = pendingChanges.isEmpty ? null : 'Есть изменения в загрузках';
    } catch (error) {
      if (!identical(api, library)) return;
      status = offline
          ? 'Нет соединения. Загруженная музыка доступна.'
          : friendly(error);
      message(status!);
    } finally {
      if (identical(api, library)) {
        refreshing = false;
        notifyListeners();
      }
    }
  }

  Future<List<LibraryItem>> root(bool playlists) async {
    if (!loggedIn) {
      return playlists ? localPlaylists.items : [LocalMusicLibrary.root];
    }
    final key = playlists ? 'playlists' : 'collections';
    if (_cache.containsKey(key)) {
      return [
        ..._cache[key]!,
        if (!playlists) LocalMusicLibrary.root,
        if (playlists) ...localPlaylists.items,
      ];
    }
    List<LibraryItem> items;
    try {
      items = playlists
          ? await library!.playlists()
          : await library!.collections();
    } catch (_) {
      if (!playlists) return [LocalMusicLibrary.root];
      if (localPlaylists.items.isNotEmpty) return localPlaylists.items;
      rethrow;
    }
    _cache[key] = items;
    await _saveCatalog();
    return [
      ...items,
      if (!playlists) LocalMusicLibrary.root,
      if (playlists) ...localPlaylists.items,
    ];
  }

  List<LibraryItem> _offlineItems(
    LibraryItem parent, {
    bool recursive = false,
  }) {
    final nodes = <String, LibraryItem>{};
    for (final list in _cache.values) {
      for (final item in list) {
        nodes[item.id] = item;
      }
    }
    for (final group in downloads!.groups.values) {
      for (final item in [group.source, ...group.folders, ...group.tracks]) {
        nodes[item.id] = item;
      }
    }
    if (parent.isPlaylist && downloads!.groups.containsKey(parent.id)) {
      return downloads!.groups[parent.id]!.tracks;
    }
    bool inside(LibraryItem item) {
      if (!recursive) return item.parentId == parent.id;
      if (parent.path.isNotEmpty && item.path.startsWith('${parent.path}/')) {
        return true;
      }
      var cursor = item.parentId;
      final visited = <String>{};
      while (cursor != null && visited.add(cursor)) {
        if (cursor == parent.id) return true;
        cursor = nodes[cursor]?.parentId;
      }
      return false;
    }

    return nodes.values.where(inside).toList()..sort(compareItems);
  }

  Future<List<LibraryItem>> children(LibraryItem parent) async {
    if (parent.isLocalPlaylist) return localPlaylists.tracks(parent.id);
    if (parent.isLocal) return localMusic.children(parent);
    if (!offline) {
      try {
        final list = await library!.children(parent);
        _cache[parent.id] = list;
        unawaited(_saveCatalog());
        return list;
      } catch (_) {
        if (!_cache.containsKey(parent.id) && downloads!.groups.isEmpty) {
          rethrow;
        }
      }
    }
    return _cache[parent.id] ?? _offlineItems(parent);
  }

  Future<List<LibraryItem>> tracks(
    LibraryItem parent, {
    bool recursive = true,
  }) async {
    if (parent.isLocalPlaylist) return localPlaylists.tracks(parent.id);
    if (parent.isLocal) return localMusic.tracks(parent, recursive: recursive);
    if (parent.isTrack) return [parent];
    if (!offline) {
      try {
        final list = await library!.tracks(parent, recursive: recursive);
        _cache[recursive ? 'recursive:${parent.id}' : parent.id] = list;
        unawaited(_saveCatalog());
        return list;
      } catch (_) {
        if (downloads!.groups.isEmpty && !_cache.containsKey(parent.id)) {
          rethrow;
        }
      }
    }
    return (recursive
            ? _offlineItems(parent, recursive: true)
            : await children(parent))
        .where((e) => e.isTrack)
        .toList();
  }

  int? knownTrackCount(LibraryItem item) {
    if (item.isTrack) return 1;
    if (item.isLocal) return localMusic.trackCount(item);
    if (item.isLocalPlaylist) return localPlaylists.trackCount(item.id);
    final known = _trackCounts.peek(item.id);
    if (known != null) return known;
    final snapshot = _cache[item.isPlaylist ? item.id : 'recursive:${item.id}'];
    if (snapshot != null) return snapshot.where((e) => e.isTrack).length;
    return downloads?.groups[item.id]?.tracks.length;
  }

  Future<int?> trackCount(LibraryItem item) async {
    if (item.isTrack ||
        item.isLocal ||
        item.isLocalPlaylist ||
        offline ||
        !loggedIn) {
      return knownTrackCount(item);
    }
    final api = library!;
    return await _trackCounts.resolve(item.id, () => api.trackCount(item)) ??
        knownTrackCount(item);
  }

  Future<List<LibraryItem>> search(LibraryItem parent, String query) async {
    final all = await tracks(parent);
    return findTracks(all, query);
  }

  OfflineAvailability offlineAvailability(LibraryItem item, {int? total}) {
    if (item.isLocal && !item.isTrack) {
      final count = localMusic.trackCount(item);
      return OfflineAvailability(available: count ?? 0, total: count);
    }
    final snapshot = item.isTrack
        ? [item]
        : item.isLocalPlaylist
        ? localPlaylists.tracks(item.id)
        : _cache['recursive:${item.id}'] ??
              (item.isPlaylist ? _cache[item.id] : null) ??
              downloads?.groups[item.id]?.tracks;
    final tracks =
        (snapshot ??
                (downloads == null
                    ? <LibraryItem>[]
                    : _offlineItems(item, recursive: true)))
            .where((track) => track.isTrack)
            .toList();
    return OfflineAvailability.resolve(
      tracks,
      total:
          total ??
          knownTrackCount(item) ??
          (snapshot == null ? null : tracks.length),
      isAvailable: (track) => track.isLocal
          ? localMusic.contains(track.id)
          : downloads?.contains(track.id) == true,
      pending: downloads?.progress.keys.toSet() ?? const {},
      errors: downloads?.errors.keys.toSet() ?? const {},
    );
  }

  bool isDownloaded(LibraryItem item) {
    if (item.isLocalPlaylist) {
      return localPlaylists.tracks(item.id).any(isDownloaded);
    }
    if (item.isLocal) return localMusic.contains(item.id);
    final manager = downloads;
    if (manager == null) return false;
    final visited = <String>{};
    bool check(LibraryItem node) {
      if (!visited.add(node.id)) return false;
      if (node.isTrack) return manager.contains(node.id);
      if ((_cache['recursive:${node.id}'] ?? []).any(
        (t) => manager.contains(t.id),
      )) {
        return true;
      }
      for (final group in manager.groups.values) {
        if (group.source.id == node.id &&
            group.tracks.any((t) => manager.contains(t.id))) {
          return true;
        }
        if (node.path.isNotEmpty &&
            group.tracks.any(
              (t) =>
                  t.path.startsWith('${node.path}/') && manager.contains(t.id),
            )) {
          return true;
        }
      }
      final children = <LibraryItem>[
        ...?_cache[node.id],
        for (final group in manager.groups.values) ...[
          if (group.source.parentId == node.id) group.source,
          ...group.folders.where((f) => f.parentId == node.id),
          ...group.tracks.where((t) => t.parentId == node.id),
        ],
      ];
      return children.any(check);
    }

    return check(item);
  }

  List<LibraryItem> downloadSelection(LibraryItem item) {
    if (item.isTrack) return [item];
    final exact = downloads!.groups[item.id];
    if (exact != null) return exact.tracks;
    final referenced = downloads!.groups.values
        .expand((g) => g.tracks)
        .map((t) => t.id)
        .toSet();
    return _offlineItems(
      item,
      recursive: true,
    ).where((t) => t.isTrack && referenced.contains(t.id)).toList();
  }

  Future<void> playTracks(
    List<LibraryItem> tracks, {
    int start = 0,
    bool randomStart = false,
    String? localPlaylistId,
    LibraryItem? serverPlaylistSource,
  }) async {
    _groupPlayRequest++;
    if (tracks.isEmpty) {
      message('В этом списке нет композиций');
      return;
    }
    await audio.player.pause();
    queue.replace(tracks, start: start, randomStart: randomStart);
    loadedLocalPlaylistId = localPlaylistId;
    if (serverPlaylistSource != null) {
      unawaited(
        serverPlaylist.open(
          library,
          serverPlaylistSource,
          baseline: tracks.map((track) => track.id).toList(),
        ),
      );
    } else {
      serverPlaylist.clear();
    }
    _restoredPosition = 0;
    wantsPlayback = true;
    await _start(queue.current);
  }

  Future<void> playGroup(LibraryItem parent) async {
    final request = ++_groupPlayRequest;
    final identity = libraryIdentity;
    final api = library;
    final items = await tracks(parent);
    if (libraryIdentity != identity || !identical(library, api)) {
      throw const AppFailure('Учётная запись изменилась');
    }
    if (request != _groupPlayRequest) return;
    await playTracks(
      items,
      randomStart: true,
      localPlaylistId: parent.isLocalPlaylist ? parent.id : null,
      serverPlaylistSource: parent.isPlaylist && !parent.isLocalPlaylist
          ? parent
          : null,
    );
  }

  Future<void> addGroup(LibraryItem parent) async {
    final items = await tracks(parent);
    queue.append(items);
    changed();
    message('Добавлено в очередь: ${items.length}');
  }

  Future<void> saveQueueAsPlaylist({
    String? name,
    bool overwrite = false,
  }) async {
    final item = await localPlaylists.save(
      queue.entries.map((e) => e.track).toList(),
      id: overwrite ? loadedLocalPlaylistId : null,
      name: name,
    );
    if (serverPlaylist.item == null) loadedLocalPlaylistId = item.id;
    localRevision++;
    await save();
    notifyListeners();
    message('Плейлист «${item.name}» сохранён');
  }

  Future<void> saveQueueToServer({bool overwriteChanged = false}) async {
    final api = library;
    final target = serverPlaylist.item;
    if (!loggedIn || offline || api == null || target == null) {
      throw const AppFailure('Для сохранения плейлиста подключитесь к серверу');
    }
    final snapshot = queue.entries.map((entry) => entry.track).toList();
    await serverPlaylist.save(
      api,
      snapshot,
      overwriteChanged: overwriteChanged,
    );
    if (library == api) {
      _cache.remove(target.id);
      _cache.remove('recursive:${target.id}');
      _trackCounts.invalidate();
      countRevision++;
      serverPlaylistRevision++;
      await _saveCatalog();
      await save();
      notifyListeners();
    }
    message('Серверный плейлист «${target.name}» сохранён');
  }

  PlaylistEditSession editServerPlaylist(LibraryItem source) {
    final api = library;
    final identity = libraryIdentity;
    bool current() => libraryIdentity == identity && identical(library, api);
    void ensureCurrent() {
      if (!current()) {
        throw const AppFailure(
          'Учётная запись изменилась. Откройте плейлист заново.',
        );
      }
    }

    return PlaylistEditSession(
      source: source,
      environment: this,
      isCurrent: current,
      isOffline: () => offline,
      server: api,
      loadTracks: () async {
        ensureCurrent();
        final list = await children(source);
        ensureCurrent();
        return list;
      },
      saveLocal: (tracks, name) async {
        ensureCurrent();
        final item = await localPlaylists.save(
          tracks,
          name: name,
          allowEmpty: true,
        );
        ensureCurrent();
        localRevision++;
        notifyListeners();
        message('Локальный плейлист «${item.name}» сохранён');
        return item;
      },
      serverSaved: () async {
        ensureCurrent();
        _cache.remove(source.id);
        _cache.remove('recursive:${source.id}');
        _trackCounts.invalidate();
        countRevision++;
        serverPlaylistRevision++;
        await _saveCatalog();
        if (current()) notifyListeners();
        message('Серверный плейлист «${source.name}» сохранён');
      },
    );
  }

  Future<void> deleteLocalPlaylist(LibraryItem item) async {
    await localPlaylists.delete(item.id);
    if (loadedLocalPlaylistId == item.id) loadedLocalPlaylistId = null;
    localRevision++;
    await save();
    notifyListeners();
    message('Локальный плейлист удалён');
  }

  Future<void> selectIndex(int index) async {
    if (index < 0 || index >= queue.entries.length) return;
    _groupPlayRequest++;
    queue.select(queue.entries[index].id);
    _restoredPosition = 0;
    wantsPlayback = true;
    await _start(queue.current);
  }

  Future<void> resume() async {
    _groupPlayRequest++;
    wantsPlayback = true;
    if (queue.current == null && queue.entries.isNotEmpty) {
      queue.select(queue.entries.first.id);
    }
    if (queue.current == null) return;
    if (_loadedEntry == queue.current?.id &&
        !waitingForNetwork &&
        audio.player.processingState.name != 'completed') {
      audio.start();
    } else {
      await _start(
        queue.current,
        position: Duration(milliseconds: _restoredPosition),
      );
    }
    changed();
  }

  Future<void> pause() async {
    _groupPlayRequest++;
    wantsPlayback = false;
    waitingForNetwork = false;
    _retryTimer?.cancel();
    _operation++;
    await audio.player.pause();
    _refreshPreload();
    await save();
    notifyListeners();
  }

  Future<void> next(bool automatic) async {
    if (!automatic) _groupPlayRequest++;
    final entry = queue.next(automatic: automatic);
    _restoredPosition = 0;
    if (entry == null) {
      wantsPlayback = false;
      await audio.player.stop();
      await _releaseStream();
      _loadedEntry = null;
      changed();
      return;
    }
    wantsPlayback = true;
    await _start(entry);
  }

  Future<void> previous() async {
    _groupPlayRequest++;
    final entry = queue.previous();
    if (entry == null) return;
    _restoredPosition = 0;
    wantsPlayback = true;
    await _start(entry);
  }

  Future<void> _start(
    QueueEntry? first, {
    Duration position = Duration.zero,
  }) async {
    if (first == null) return;
    final operation = ++_operation;
    // Loading the explicitly selected track always takes priority over a
    // speculative download. Completed cached files remain available.
    preloader?.cancelPending();
    waitingForNetwork = false;
    _retryTimer?.cancel();
    await audio.player.pause();
    _loadedEntry = null;
    await _releaseStream();
    QueueEntry? entry = first;
    var serverUnavailable = false;
    final attempted = <String>{};
    while (entry != null && attempted.add(entry.id)) {
      if (operation != _operation) return;
      audio.publishQueue(queue, position: position);
      notifyListeners();
      final speculative = preloader?.localPath(entry.track.id);
      final local = entry.track.isLocal
          ? localMusic.pathFor(entry.track)
          : downloads?.localPath(entry.track.id) ?? speculative;
      String? requestedSession;
      try {
        final hasLocal = local != null && await File(local).exists();
        if (!hasLocal &&
            (entry.track.isLocal ||
                library == null ||
                !_streamAllowed ||
                serverUnavailable)) {
          throw const AppFailure('Нет соединения');
        }
        if (!hasLocal && library!.requiresConversion(entry.track)) {
          requestedSession =
              'simplefy-${DateTime.now().microsecondsSinceEpoch}-$operation';
        }
        await audio.load(
          hasLocal
              ? Uri.file(local)
              : library!.streamUri(
                  entry.track,
                  playSessionId: requestedSession,
                ),
          hasLocal ? {} : library!.headers,
          position: position,
        );
        if (operation != _operation) {
          if (requestedSession != null) {
            await library?.releaseStream(requestedSession);
          }
          return;
        }
        // The source is still paused: apply the new track's gain before its
        // first audible sample, even when the previous track had metadata.
        await _applyNormalization(entry.track);
        if (operation != _operation) {
          if (requestedSession != null) {
            await library?.releaseStream(requestedSession);
          }
          return;
        }
        _convertedSession = requestedSession;
        _loadedEntry = entry.id;
        _loadedFromFile = hasLocal;
        _restoredPosition = position.inMilliseconds;
        _skipCount = 0;
        status = null;
        if (wantsPlayback) audio.start();
        changed();
        return;
      } catch (_) {
        if (requestedSession != null) {
          await library?.releaseStream(requestedSession);
        }
        if (operation != _operation) return;
        if (local != null && local == speculative) {
          await preloader?.invalidate(entry.track.id);
          attempted.remove(entry.id);
          continue;
        }
        if (local != null && downloads?.contains(entry.track.id) == true) {
          await downloads!.invalidate(entry.track.id);
        }
        if (!entry.track.isLocal &&
            library != null &&
            _streamAllowed &&
            !serverUnavailable) {
          final available = await library!.availability(entry.track);
          if (operation != _operation) return;
          if (available == SourceAvailability.unauthorized) {
            await pause();
            status = 'Сессия истекла. Войдите в учётную запись заново.';
            message(status!);
            return;
          }
          serverUnavailable = available == SourceAvailability.unreachable;
        }
        _reportUnavailable(entry.track);
        entry = queue.next();
        position = Duration.zero;
      }
    }
    await audio.player.stop();
    _loadedEntry = null;
    status = 'Нет доступных композиций';
    if (!first.track.isLocal &&
        (!_streamAllowed || serverUnavailable) &&
        wantsPlayback) {
      queue.select(first.id);
      waitingForNetwork = true;
      _scheduleRetry();
    } else {
      wantsPlayback = false;
    }
    changed();
    message(status!);
  }

  void _playbackError(Object error) {
    if (!wantsPlayback || waitingForNetwork || _loadedEntry == null) return;
    _restoredPosition = audio.player.position.inMilliseconds;
    if (_lastFailureEntry == _loadedEntry &&
        (_restoredPosition - _failurePosition).abs() < 2000) {
      _recoveryAttempts++;
    } else {
      _recoveryAttempts = 1;
    }
    _lastFailureEntry = _loadedEntry;
    _failurePosition = _restoredPosition;
    waitingForNetwork = true;
    status = 'Соединение прервано. Ожидаем восстановления';
    unawaited(audio.player.pause());
    unawaited(_recoverSource());
    notifyListeners();
  }

  Future<void> _recoverSource() async {
    final entry = queue.current;
    final operation = _operation;
    if (entry == null) return;
    if (entry.track.isLocal) {
      waitingForNetwork = false;
      _reportUnavailable(entry.track);
      await next(false);
      return;
    }
    if (library == null) return;
    if (_loadedFromFile) {
      await downloads!.invalidate(entry.track.id);
      if (operation == _operation && wantsPlayback) {
        await _start(
          entry,
          position: Duration(milliseconds: _restoredPosition),
        );
      }
      return;
    }
    final available = await library!.availability(entry.track);
    if (operation != _operation || !wantsPlayback) return;
    if (available == SourceAvailability.missing ||
        (available == SourceAvailability.available && _recoveryAttempts >= 3)) {
      waitingForNetwork = false;
      _reportUnavailable(entry.track);
      await next(false);
    } else if (available == SourceAvailability.unauthorized) {
      await pause();
      status = 'Сессия истекла. Войдите в учётную запись заново.';
      message(status!);
    } else {
      _scheduleRetry();
    }
  }

  void _reportUnavailable(LibraryItem track) {
    _skipCount++;
    final text = 'Трек «${track.title}» недоступен';
    message(text);
    unawaited(
      notifications
          .show(
            id: 41,
            title: 'Пропущено композиций: $_skipCount',
            body: text,
            notificationDetails: const NotificationDetails(
              android: AndroidNotificationDetails(
                'unavailable-tracks',
                'Недоступные композиции',
                channelDescription: 'Сообщения о пропущенных композициях',
                importance: Importance.low,
                priority: Priority.low,
                playSound: false,
                enableVibration: false,
                onlyAlertOnce: true,
              ),
              iOS: DarwinNotificationDetails(
                presentSound: false,
                threadIdentifier: 'unavailable-tracks',
              ),
            ),
          )
          .catchError((Object error) {
            // Denied notification permission must never stop audio or queue traversal.
          }),
    );
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 8), () {
      if (wantsPlayback && waitingForNetwork && _streamAllowed) {
        unawaited(resume());
      } else if (wantsPlayback && waitingForNetwork) {
        _scheduleRetry();
      }
    });
  }

  void setShuffle(bool value) {
    queue.shuffled = value;
    changed();
  }

  void setRepeat(RepeatMode value) {
    queue.repeat = value;
    changed();
  }

  void move(int from, int to) {
    queue.move(from, to);
    changed();
  }

  Future<void> remove(String id, {bool finish = false}) async {
    final current = queue.remove(id);
    if (current && !finish) await next(false);
    changed();
  }

  void changed() {
    _refreshPreload();
    audio.publishQueue(queue, position: hasLoadedCurrent ? null : position);
    notifyListeners();
    unawaited(save());
  }

  void _refreshPreload() {
    final next = wantsPlayback && hasLoadedCurrent ? queue.previewNext() : null;
    preloader?.prepare(
      next == null ||
              next.id == queue.current?.id ||
              downloads?.contains(next.track.id) == true
          ? null
          : next.track,
      currentId: queue.current?.track.id,
      allowed: _streamAllowed,
    );
  }

  void setBrowse(int tab, List<LibraryItem> path) {
    browse = BrowseLocation(tab: tab, path: List.unmodifiable(path));
    unawaited(save());
  }

  Future<void> importMusic({required bool folder}) async {
    if (importing) return;
    importing = true;
    notifyListeners();
    try {
      final count = await localMusic.import(folder: folder);
      if (count != null) {
        localRevision++;
        message(
          count > 0
              ? 'Импортировано композиций: $count'
              : 'В выбранном месте нет поддерживаемых аудиофайлов',
        );
      }
    } finally {
      importing = false;
      notifyListeners();
    }
  }

  Future<void> removeImported(LibraryItem item) async {
    final ids = {item.id, ...localMusic.tracks(item).map((e) => e.id)};
    if (ids.contains(queue.current?.track.id) && _loadedFromFile) {
      await stop();
    }
    await localMusic.remove(item);
    localRevision++;
    notifyListeners();
  }

  void message(String text) {
    messages.add(text);
  }

  static String friendly(Object error) => error is FormatException
      ? error.message
      : error is AppFailure
      ? error.message
      : 'Не удалось выполнить операцию. Проверьте подключение и повторите.';

  Future<void> requestNotifications() async {
    await notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
    await notifications
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.requestPermissions(alert: true, badge: false, sound: false);
  }

  Future<void> _applyNormalization(
    LibraryItem? track, {
    bool smooth = false,
  }) async {
    try {
      await audio.setPlaybackGain(
        normalizedVolume(track, normalizationMode),
        smooth: smooth,
      );
    } catch (_) {
      // A volume-control error is not a missing/corrupt audio file. In
      // particular it must never invalidate an existing offline download.
      message('Не удалось применить выравнивание громкости');
    }
  }

  Future<void> setVolumeNormalization(VolumeNormalizationMode mode) async {
    normalizationMode = mode;
    notifyListeners();
    final persistence = save();
    await _applyNormalization(
      queue.current?.track,
      smooth: hasLoadedCurrent && isPlaying,
    );
    await persistence;
  }

  Future<void> setMobileDownloads(bool value) async {
    allowMobileDownloads = value;
    await downloads!.setCellular(value);
    await save();
    notifyListeners();
  }

  Future<void> removeDownloadedTrack(LibraryItem track) async {
    final manager = downloads;
    if (manager == null || !loggedIn) {
      throw const AppFailure('Учётная запись изменилась');
    }
    if (queue.current?.track.id == track.id) await releaseLocalAudio();
    if (!identical(downloads, manager)) {
      throw const AppFailure('Учётная запись изменилась');
    }
    await manager.removeTrack(track.id);
    message('Композиция удалена с устройства');
  }

  Future<void> releaseLocalAudio() async {
    if (!_loadedFromFile || !hasLoadedCurrent) return;
    if (queue.current == null ||
        downloads?.contains(queue.current!.track.id) != true) {
      return;
    }
    _restoredPosition = audio.player.position.inMilliseconds;
    await pause();
    await audio.player.stop();
    _loadedEntry = null;
    await save();
    changed();
  }

  Future<void> _releaseStream() async {
    final session = _convertedSession;
    _convertedSession = null;
    if (session != null) await library?.releaseStream(session);
  }

  Future<void> stop() async {
    final savedPosition = position.inMilliseconds;
    await pause();
    await audio.player.stop();
    _loadedEntry = null;
    _restoredPosition = savedPosition;
    await _releaseStream();
    changed();
    await save();
  }

  Future<void> seek(Duration value) async {
    if (hasLoadedCurrent) {
      await audio.player.seek(value);
    } else {
      _restoredPosition = value.inMilliseconds;
    }
    changed();
  }

  Future<void> setMobileStreaming(bool value) async {
    allowMobileStreaming = value;
    if (!_streamAllowed &&
        isPlaying &&
        queue.current != null &&
        !_loadedFromFile) {
      _restoredPosition = audio.player.position.inMilliseconds;
      waitingForNetwork = true;
      await audio.player.pause();
    }
    await save();
    _refreshPreload();
    if (_streamAllowed && waitingForNetwork && wantsPlayback) {
      unawaited(resume());
    }
    notifyListeners();
  }

  void setOnlyDownloaded(bool value) {
    onlyDownloaded = value;
    notifyListeners();
    unawaited(save());
  }

  Future<void> applyChanges() async {
    for (final change in List.of(pendingChanges)) {
      final current = downloads!.groups[change.before.source.id];
      if (current == null || current.fingerprint != change.before.fingerprint) {
        continue;
      }
      await downloads!.apply(change.after);
    }
    pendingChanges = [];
    status = null;
    notifyListeners();
  }

  Future<void> resumeTransfers() async {
    if (!loggedIn) return;
    try {
      await downloads!.reconcile();
    } catch (error) {
      message(friendly(error));
    }
    if (waitingForNetwork && wantsPlayback && _streamAllowed) {
      unawaited(resume());
    }
  }

  @override
  void dispose() {
    audio.cancelGainAdjustment();
    _trackCounts.dispose();
    _networkSubscription?.cancel();
    _playingSubscription?.cancel();
    _positionSubscription?.cancel();
    _retryTimer?.cancel();
    downloads?.dispose();
    preloader?.dispose();
    library?.close();
    messages.close();
    serverPlaylist.removeListener(_serverPlaylistChanged);
    serverPlaylist.dispose();
    super.dispose();
  }
}
