import 'playback_availability.dart';
import 'package:flutter/services.dart';
import '../l10n/l10n.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../domain/download_group.dart';
import '../domain/download_activity.dart';
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
import 'diagnostics.dart';
import 'playback_coordinator.dart';
import '../infrastructure/playback_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'playlist_mutations.dart';
import 'language_settings.dart';
import 'catalog_cache.dart';
import 'track_count_cache.dart';
import 'playlist_edit_session.dart';
import 'server_playlist_editor.dart';

class AppController extends ChangeNotifier {
  AppController(
    this.store,
    this.audio, {
    NetworkMonitor? network,
    Future<ServerSession> Function(String, String, String, String)?
    authenticate,
    JellyfinLibrary Function(ServerSession, String)? libraryFactory,
    DownloadManager Function(LocalStore, JellyfinLibrary)? downloadFactory,
    Future<Directory> Function()? cacheDirectory,
    LanguageSettings? languages,
  }) : authenticate =
           authenticate ??
           ((server, username, password, device) => JellyfinLibrary.login(
             server,
             username,
             password,
             deviceId: device,
           )),
       libraryFactory =
           libraryFactory ??
           ((session, device) => JellyfinLibrary(session, deviceId: device)),
       downloadFactory =
           downloadFactory ??
           ((store, library) => DownloadManager(store, library)),
       cacheDirectory = cacheDirectory ?? getApplicationCacheDirectory,
       network = network ?? DeviceNetworkMonitor(),
       languages =
           languages ??
           LanguageSettings(store, systemLanguage: L10n.current.localeName) {
    this.languages.addListener(_languageChanged);
    serverPlaylist.addListener(_serverPlaylistChanged);
    _updatePlaybackAvailability();
  }
  final Future<ServerSession> Function(String, String, String, String)
  authenticate;
  final JellyfinLibrary Function(ServerSession, String) libraryFactory;
  final DownloadManager Function(LocalStore, JellyfinLibrary) downloadFactory;
  final Future<Directory> Function() cacheDirectory;
  late final _playback = PlaybackCoordinator(
    queue: queue,
    audio: PlaybackAudioAdapter(audio),
    libraryProvider: () => library,
    downloadsProvider: () => downloads,
    prefetchProvider: () => preloader,
    importedPath: (track) => localMusic.pathFor(track),
    streamAllowed: () => _streamAllowed,
    changed: changed,
    notifyListeners: notifyListeners,
    message: message,
    statusReader: () => _status,
    statusWriter: (value) => status = value,
    next: (automatic) => next(automatic),
    pause: pause,
    resume: resume,
    applyNormalization: (track) => _applyNormalization(track),
    reportUnavailable: _reportUnavailable,
    resetSkipped: () => _skipCount = 0,
  );
  late final _availability = PlaybackAvailability(
    streamingAllowed: () => _streamAllowed,
    offline: () => offline,
    hasLocal: isDownloaded,
  );

  void _updatePlaybackAvailability() {
    queue.setPlaybackFilter(
      _availability.canPlay,
      version: (
        _streamAllowed,
        downloads,
        downloads?.availabilityRevision,
        localRevision,
      ),
    );
  }

  Object? _dimStamp;
  final Map<String, bool> _dimmed = {};
  bool isUnavailable(LibraryItem item) {
    if (!offline) return false;
    if (item.isTrack) return _availability.isUnavailable(item);
    final stamp = (
      catalogRevision,
      localRevision,
      downloads,
      downloads?.availabilityRevision,
    );
    if (_dimStamp != stamp) {
      _dimStamp = stamp;
      _dimmed.clear();
    }
    return _dimmed.putIfAbsent(
      item.id,
      () => _availability.isUnavailable(item),
    );
  }

  @override
  void notifyListeners() {
    _updatePlaybackAvailability();
    super.notifyListeners();
  }

  final NetworkMonitor network;
  final LanguageSettings languages;
  void _languageChanged() {
    downloads?.localeChanged();
    if (initialized) unawaited(_refreshNotificationLanguages());
    notifyListeners();
  }

  Future<void> _refreshNotificationLanguages() async {
    final android = notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return;
    try {
      await android.createNotificationChannel(
        AndroidNotificationChannel(
          'online.tavhome.simplefy.audio',
          L10n.current.music,
          importance: Importance.low,
        ),
      );
      await android.createNotificationChannel(
        AndroidNotificationChannel(
          'unavailable-tracks',
          L10n.current.unavailableTracks,
          description: L10n.current.notificationsAboutSkippedTracks,
          importance: Importance.low,
        ),
      );
    } on Object catch (error) {
      Diagnostics.record('controller-recovery', error);
      // Notification metadata must never interrupt playback or a locale change.
    }
  }

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
  Object? _dirtyStamp;
  bool _dirtyValue = false;
  bool get queueHasChanges {
    final stamp = (
      queue.entries,
      serverPlaylist.revision,
      localRevision,
      loadedLocalPlaylistId,
    );
    if (_dirtyStamp == stamp) return _dirtyValue;
    _dirtyStamp = stamp;
    return _dirtyValue = _computeQueueHasChanges();
  }

  bool _computeQueueHasChanges() {
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
  late final _catalog = CatalogCache(
    _cache,
    onChanged: () {
      catalogRevision++;
      notifyListeners();
    },
    onStored: _scheduleCatalogSave,
  );
  int catalogRevision = 0;
  Timer? _catalogSaveTimer;
  LibraryItem? preparingGroup;
  int? _preparingRequest;
  bool resolvingGroup = false;
  Object? _groupPreparationError;
  String? get groupPreparationError => _groupPreparationError == null
      ? null
      : _groupPreparationError is String
      ? _groupPreparationError as String
      : friendly(_groupPreparationError!);
  set groupPreparationError(Object? value) => _groupPreparationError = value;
  LibraryItem? failedGroup;

  bool catalogUpdating(String key) => _catalog.updating(key);
  Object? catalogError(String key) => _catalog.errors[key];
  List<LibraryItem>? peekRoot(bool playlists) {
    if (!loggedIn) {
      return playlists ? localPlaylists.items : [LocalMusicLibrary.root];
    }
    final saved = _cache[playlists ? 'playlists' : 'collections'];
    return saved == null
        ? null
        : [
            ...saved,
            if (!playlists) LocalMusicLibrary.root,
            if (playlists) ...localPlaylists.items,
          ];
  }

  List<LibraryItem>? peekChildren(LibraryItem parent) {
    if (parent.isLocalPlaylist) return localPlaylists.tracks(parent.id);
    if (parent.isLocal) return localMusic.children(parent);
    return _cache[parent.id];
  }

  void _resetCatalogRequests() {
    _serverRetry?.cancel();
    _catalog.invalidate();
    _cache.clear();
    _catalogSaveTimer?.cancel();
    preparingGroup = null;
    _preparingRequest = null;
    resolvingGroup = false;
    groupPreparationError = null;
    failedGroup = null;
  }

  void _scheduleCatalogSave() {
    _catalogSaveTimer?.cancel();
    final api = library;
    _catalogSaveTimer = Timer(const Duration(milliseconds: 250), () {
      if (identical(library, api) && downloads != null) {
        unawaited(_saveCatalog());
      }
    });
  }

  List<DownloadChange> pendingChanges = [];
  bool initialized = false;
  bool _sessionReady = false;
  bool _persistenceErrorShown = false;
  bool refreshing = false;
  VolumeNormalizationMode normalizationMode = VolumeNormalizationMode.track;
  bool allowMobileStreaming = true;
  bool allowMobileDownloads = true;
  bool onlyDownloaded = false;
  bool miniPlayerCollapsed = false;

  void setMiniPlayerCollapsed(bool value) {
    if (miniPlayerCollapsed == value) return;
    miniPlayerCollapsed = value;
    notifyListeners();
    unawaited(_persist('player_ui', {'collapsed': value}));
  }

  bool get waitingForNetwork => _playback.waitingForNetwork;
  set waitingForNetwork(bool value) => _playback.waitingForNetwork = value;
  bool get wantsPlayback => _playback.wantsPlayback;
  set wantsPlayback(bool value) => _playback.wantsPlayback = value;
  Object? _status;
  String? get status => _status == null
      ? null
      : _status is AppMessage || _status is String
      ? _status.toString()
      : friendly(_status!);
  set status(Object? value) => _status = value;
  String? get _loadedEntry => _playback.loadedEntry;
  set _loadedEntry(String? value) => _playback.loadedEntry = value;
  bool get _loadedFromFile => _playback.loadedFromFile;
  int get _operation => _playback.operation;
  set _operation(int value) => _playback.operation = value;
  int _groupPlayRequest = 0;
  int _skipCount = 0;
  int get _restoredPosition => _playback.restoredPosition;
  set _restoredPosition(int value) => _playback.restoredPosition = value;
  DateTime _lastSave = DateTime(2000);
  NetworkKind _connection = NetworkKind.other;
  StreamSubscription<NetworkKind>? _networkSubscription;
  Timer? _serverRetry;
  bool _serverChecksClosed = false;
  StreamSubscription<bool>? _playingSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  Timer? get _retryTimer => _playback.retryTimer;

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
  bool get offline =>
      _connection == NetworkKind.offline ||
      (library?.serverUnavailable ?? false);
  bool get _streamAllowed =>
      !offline &&
      (allowMobileStreaming || _connection == NetworkKind.unmetered);
  String get _account => downloads!.namespace;
  String get _stateKey =>
      loggedIn || downloads != null ? 'state_$_account' : 'state_local';
  String get _catalogKey => 'catalog_$_account';

  Future<void> initialize({String bootstrapSession = ''}) async {
    try {
      await _initialize(bootstrapSession: bootstrapSession);
    } on Object catch (error) {
      Diagnostics.record('initialize', error);
      status = AppMessage.couldNotRestoreTheConnectionSignIn;
      message(status!);
    } finally {
      initialized = true;
      notifyListeners();
    }
  }

  Future<void> _initialize({String bootstrapSession = ''}) async {
    final playerUi = await store.read('player_ui');
    miniPlayerCollapsed = playerUi['collapsed'] == true;
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
      final wasOffline = offline;
      _connection = value;
      _updatePlaybackAvailability();
      if (value != NetworkKind.offline &&
          library != null &&
          (wasOffline || library!.serverUnavailable)) {
        unawaited(library!.checkConnection());
      }
      downloads?.setNetwork(offline ? NetworkKind.offline : value);
      if (value == NetworkKind.offline) {
        status = AppMessage.noConnectionDownloadedMusicIsAvailable;
        message(status!);
      }
      _refreshPreload();
      if (!_streamAllowed &&
          isPlaying &&
          queue.current != null &&
          !_loadedFromFile) {
        await _playback.connectionLost();
      } else if (_streamAllowed && waitingForNetwork && wantsPlayback) {
        unawaited(resume());
      }
      notifyListeners();
    });
    audio.shouldAutoAdvance = () =>
        wantsPlayback && !waitingForNetwork && hasLoadedCurrent;
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
        unawaited(savePosition());
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
      } on Object catch (error) {
        Diagnostics.record('controller-recovery', error);
        status = AppMessage.couldNotRestoreTheConnectionSignIn;
        message(status!);
      }
    }
    if (!loggedIn) await _restoreState(await store.read(_stateKey));
    initialized = true;
    unawaited(_refreshNotificationLanguages());
    notifyListeners();
    if (loggedIn) unawaited(refresh());
  }

  Future<void> login(String server, String username, String password) async {
    if (_loggingOut != null) {
      throw const AppFailure(AppMessage.waitForTheCurrentOperationToFinish);
    }
    final session = await authenticate(server, username, password, _deviceId);
    if (hasLibrary) await stop();
    await store.saveSession(jsonEncode(session.toJson()));
    await _attach(session);
    notifyListeners();
    unawaited(refresh());
  }

  Future<void> _attach(ServerSession session) async {
    try {
      await _attachSession(session);
    } on Object {
      _resetCatalogRequests();
      downloads?.dispose();
      preloader?.dispose();
      library?.close();
      downloads = null;
      preloader = null;
      library = null;
      _sessionReady = false;
      loadedLocalPlaylistId = null;
      localPlaylists.clearScope();
      serverPlaylist.clear();
      queue.replace([]);
      rethrow;
    }
  }

  Future<void> _attachSession(ServerSession session) async {
    _resetCatalogRequests();
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
    library = libraryFactory(session, _deviceId);
    final attached = library!;
    attached.onConnectionChanged = (available) {
      if (!identical(library, attached)) return;
      downloads?.setNetwork(offline ? NetworkKind.offline : _connection);
      if (!available) {
        _updatePlaybackAvailability();
        unawaited(_playback.connectionLost());
        status = AppMessage.noConnectionDownloadedMusicIsAvailable;
        message(status!);
        _scheduleServerCheck(attached);
      } else {
        _serverRetry?.cancel();
        status = null;
        if (waitingForNetwork && wantsPlayback) unawaited(resume());
      }
      _updatePlaybackAvailability();
      _refreshPreload();
      notifyListeners();
    };
    downloads = downloadFactory(store, library!);
    final cacheRoot = await cacheDirectory();
    final cache = Directory(
      p.join(cacheRoot.path, 'simplefy-prefetch', _account),
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
    downloads!.setNetwork(_connection);
    unawaited(downloads!.retryPending());
    final saved = await store.read(_catalogKey);
    _cache.clear();
    _cache.addAll(await compute(_decodeCatalogSnapshot, saved));
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
        for (final e
            in (savedCounts['counts'] is Map
                    ? savedCounts['counts'] as Map
                    : {})
                .entries)
          if (e.key is String && e.value is num && (e.value as num) >= 0)
            e.key as String: (e.value as num).toInt(),
      },
      onChanged: (values) => unawaited(_persist(countKey, {'counts': values})),
    );
    countRevision++;
    await localPlaylists.load(_stateKey);
    loadedLocalPlaylistId = (state['localPlaylistId'] is String
        ? state['localPlaylistId'] as String
        : null);
    if (loadedLocalPlaylist == null) loadedLocalPlaylistId = null;
    unawaited(
      serverPlaylist.restore(
        library,
        state['serverPlaylist'] is Map
            ? Map<String, dynamic>.from(state['serverPlaylist'] as Map)
            : null,
      ),
    );
    normalizationMode = VolumeNormalizationMode.restore(
      state['volumeNormalization'],
    );
    allowMobileStreaming = state['mobileStreaming'] is bool
        ? state['mobileStreaming'] as bool
        : true;
    allowMobileDownloads = state['mobileDownloads'] is bool
        ? state['mobileDownloads'] as bool
        : true;
    onlyDownloaded = state['onlyDownloaded'] is bool
        ? state['onlyDownloaded'] as bool
        : false;
    queue.restore(
      state['queue'] is Map
          ? Map<String, dynamic>.from(state['queue'] as Map)
          : {},
    );
    _restoredPosition = state['position'] is int
        ? (state['position'] as int).clamp(0, 1 << 53)
        : 0;
    final savedBrowse = await store.read('browse_$_stateKey');
    browse = BrowseLocation.fromJson(
      savedBrowse.isNotEmpty
          ? savedBrowse
          : state['browse'] is Map
          ? Map<String, dynamic>.from(state['browse'] as Map)
          : {},
    );
    final head = await store.read('playhead_$_stateKey');
    if (queue.current != null &&
        head['entryId'] == queue.current!.id &&
        head['position'] is int) {
      _restoredPosition = (head['position'] as int).clamp(0, 1 << 53);
    }
    audio.publishQueue(
      queue,
      position: Duration(milliseconds: _restoredPosition),
    );
  }

  Future<void>? _loggingOut;
  Future<void> logout() =>
      _loggingOut ??= _logout().whenComplete(() => _loggingOut = null);
  Future<void> _logout() async {
    final api = library;
    final manager = downloads;
    var remoteCleanupFailed = false;
    try {
      await stop();
      await save();
    } on Object catch (error) {
      Diagnostics.record('logout-stop', error);
    }
    _operation++;
    _resetCatalogRequests();
    preloader?.dispose();
    preloader = null;
    try {
      await manager?.forgetSession();
    } on Object catch (error) {
      remoteCleanupFailed = true;
      Diagnostics.record('logout-downloads', error);
    }
    try {
      await api?.logout();
    } on Object catch (error) {
      remoteCleanupFailed = true;
      Diagnostics.record('logout-revoke', error);
    }
    try {
      await store.deleteSession();
    } finally {
      manager?.dispose();
      api?.close();
      downloads = null;
      library = null;
      _sessionReady = false;
      _cache.clear();
      pendingChanges = [];
      queue.replace([]);
      browse = const BrowseLocation();
      _loadedEntry = null;
      loadedLocalPlaylistId = null;
      localPlaylists.clearScope();
      serverPlaylist.clear();
      try {
        await _restoreState(await store.read(_stateKey));
      } on Object catch (error) {
        Diagnostics.record('logout-local-state', error);
      }
      notifyListeners();
    }
    if (remoteCleanupFailed) message(AppMessage.sessionRevocationFailed);
  }

  Future<void> save() async {
    if (!initialized && !loggedIn) return;
    if (downloads != null && !_sessionReady) return;
    await _persist('browse_$_stateKey', browse.toJson());
    await savePosition();
    await _persist(_stateKey, {
      'queue': queue.capture(),
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

  Future<void> savePosition() async {
    if ((!initialized && !loggedIn) || (downloads != null && !_sessionReady)) {
      return;
    }
    await _persist('playhead_$_stateKey', {
      'entryId': queue.current?.id,
      'position': position.inMilliseconds,
    });
  }

  Future<void> _saveCatalog() async {
    if (downloads == null) return;
    final api = library;
    final key = _catalogKey;
    final snapshot = Map<String, List<LibraryItem>>.of(_cache);
    final data = await compute(_catalogSnapshot, snapshot);
    if (identical(api, library)) await _persist(key, data);
  }

  Future<void> _persist(String key, Map<String, dynamic> data) async {
    try {
      await store.write(key, data);
      _persistenceErrorShown = false;
    } on Object catch (error) {
      Diagnostics.record('controller-recovery', error);
      if (!_persistenceErrorShown) {
        _persistenceErrorShown = true;
        message(AppMessage.couldNotSaveTheAppStateCheck);
      }
    }
  }

  void _scheduleServerCheck(JellyfinLibrary api) {
    if (_serverChecksClosed) return;
    _serverRetry?.cancel();
    _serverRetry = Timer(const Duration(seconds: 8), () async {
      if (_serverChecksClosed || !identical(library, api)) return;
      if (_connection != NetworkKind.offline) await api.checkConnection();
      if (!_serverChecksClosed &&
          identical(library, api) &&
          api.serverUnavailable) {
        _scheduleServerCheck(api);
      }
    });
  }

  Future<void> refresh() async {
    if (refreshing || !loggedIn) return;
    if (_connection == NetworkKind.offline) {
      status = AppMessage.noConnectionDownloadedMusicIsAvailable;
      message(status!);
      notifyListeners();
      return;
    }
    if (library!.serverUnavailable && !await library!.checkConnection()) return;
    unawaited(serverPlaylist.refreshAccess(library));
    final api = library!;
    final manager = downloads!;
    refreshing = true;
    notifyListeners();
    try {
      await Future.wait([
        _catalog.refresh('collections', api.collections),
        _catalog.refresh('playlists', api.playlists),
      ]);
      if (!identical(api, library)) return;
      notifyListeners();
      final changes = await manager.changes();
      if (!identical(api, library)) return;
      _trackCounts.invalidate();
      countRevision++;
      // Retain visited snapshots; visible pages revalidate after refresh.
      pendingChanges = changes;
      await _saveCatalog();
      status = pendingChanges.isEmpty ? null : AppMessage.downloadsHaveChanged;
    } on Object catch (error) {
      if (!identical(api, library)) return;
      status = offline
          ? AppMessage.noConnectionDownloadedMusicIsAvailable
          : error;
      message(status!);
    } finally {
      if (identical(api, library)) {
        refreshing = false;
        notifyListeners();
      }
    }
  }

  Future<List<LibraryItem>> root(bool playlists) async {
    if (!loggedIn) return peekRoot(playlists)!;
    final key = playlists ? 'playlists' : 'collections';
    final api = library!;
    if (offline) {
      return peekRoot(playlists) ??
          (playlists ? localPlaylists.items : [LocalMusicLibrary.root]);
    }
    try {
      await _catalog.read(
        key,
        () => playlists ? api.playlists() : api.collections(),
      );
    } on Object catch (error) {
      Diagnostics.record('controller-recovery', error);
      if (_cache.containsKey(key)) return peekRoot(playlists)!;
      if (!playlists) return [LocalMusicLibrary.root];
      if (localPlaylists.items.isNotEmpty) return localPlaylists.items;
      rethrow;
    }
    if (!identical(api, library)) {
      throw const AppFailure(AppMessage.theAccountHasChanged);
    }
    return peekRoot(playlists)!;
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

  Future<List<LibraryItem>> children(LibraryItem parent) => _children(parent);
  Future<List<LibraryItem>> freshChildren(LibraryItem parent) =>
      _children(parent, fresh: true);

  Future<List<LibraryItem>> _children(
    LibraryItem parent, {
    bool fresh = false,
  }) async {
    if (parent.isLocalPlaylist) return localPlaylists.tracks(parent.id);
    if (parent.isLocal) return localMusic.children(parent);
    if (!offline) {
      final api = library!;
      try {
        return await _catalog.read(
          parent.id,
          () => api.children(parent),
          fresh: fresh,
        );
      } on Object catch (error) {
        Diagnostics.record('controller-recovery', error);
        if (!_cache.containsKey(parent.id) &&
            (downloads?.groups.isEmpty ?? true)) {
          rethrow;
        }
      }
    }
    return _cache[parent.id] ?? _offlineItems(parent);
  }

  Object? _searchStamp;
  Future<List<LibraryItem>>? _searchTracks;

  /// Shared across search and playlist pickers; catalogue revisions invalidate it.
  Future<List<LibraryItem>> searchTracks([LibraryItem? scope]) {
    if (scope != null) return tracks(scope);
    final stamp = (libraryIdentity, catalogRevision, localRevision, offline);
    if (_searchStamp == stamp && _searchTracks != null) return _searchTracks!;
    _searchStamp = stamp;
    final identity = libraryIdentity;
    late final Future<List<LibraryItem>> result;
    result = () async {
      try {
        final groups = <List<LibraryItem>>[];
        for (final collection in await root(false)) {
          groups.add(await tracks(collection));
          if (identity != libraryIdentity) {
            throw const AppFailure(AppMessage.theAccountHasChanged);
          }
        }
        final items = await assembleSearchTracks(groups);
        if (identity != libraryIdentity) {
          throw const AppFailure(AppMessage.theAccountHasChanged);
        }
        if (identical(_searchTracks, result)) {
          _searchStamp = (
            libraryIdentity,
            catalogRevision,
            localRevision,
            offline,
          );
        }
        return List<LibraryItem>.unmodifiable(items);
      } on Object {
        if (identical(_searchTracks, result)) _searchTracks = null;
        rethrow;
      }
    }();
    return _searchTracks = result;
  }

  Future<List<LibraryItem>> tracks(
    LibraryItem parent, {
    bool recursive = true,
  }) async {
    if (parent.isLocalPlaylist) return localPlaylists.tracks(parent.id);
    if (parent.isLocal) return localMusic.tracks(parent, recursive: recursive);
    if (parent.isTrack) return [parent];
    final key = recursive ? 'recursive:${parent.id}' : parent.id;
    if (!offline) {
      final api = library!;
      try {
        return await _catalog.read(
          key,
          () => api.tracks(parent, recursive: recursive),
        );
      } on Object catch (error) {
        Diagnostics.record('controller-recovery', error);
        if ((downloads?.groups.isEmpty ?? true) &&
            !_cache.containsKey(key) &&
            !_cache.containsKey(parent.id)) {
          rethrow;
        }
      }
    }
    if (_cache[key] case final saved?) {
      return saved.where((e) => e.isTrack).toList();
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
      message(AppMessage.thisListHasNoTracks);
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

  Future<bool> playGroup(LibraryItem parent) async {
    final request = ++_groupPlayRequest;
    final identity = libraryIdentity;
    final api = library;
    preparingGroup = parent;
    _preparingRequest = request;
    resolvingGroup = true;
    groupPreparationError = null;
    failedGroup = null;
    notifyListeners();
    try {
      final items = await tracks(parent);
      if (libraryIdentity != identity || !identical(library, api)) {
        throw const AppFailure(AppMessage.theAccountHasChanged);
      }
      if (request != _groupPlayRequest) return false;
      if (items.isEmpty) throw const AppFailure(AppMessage.thisListHasNoTracks);
      resolvingGroup = false;
      notifyListeners();
      await playTracks(
        items,
        randomStart: true,
        localPlaylistId: parent.isLocalPlaylist ? parent.id : null,
        serverPlaylistSource: parent.isPlaylist && !parent.isLocalPlaylist
            ? parent
            : null,
      );
      return true;
    } on Object catch (error) {
      if (_preparingRequest == request &&
          _groupPlayRequest <= request + 1 &&
          identical(library, api)) {
        groupPreparationError = error;
        failedGroup = parent;
      }
      rethrow;
    } finally {
      // playTracks increments the request once; a newer user action must win.
      if (_preparingRequest == request) {
        preparingGroup = null;
        _preparingRequest = null;
        resolvingGroup = false;
        notifyListeners();
      }
    }
  }

  Future<void> addGroup(LibraryItem parent) async {
    final items = await tracks(parent);
    queue.append(items);
    changed();
    message(AppMessage.addedToQueue(items.length));
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
    message(AppMessage.playlistSaved(item.name));
  }

  final playlistMutations = PlaylistMutations();
  bool creatingServerPlaylist = false;

  Future<void> createServerPlaylistFromQueue(String name) async {
    final api = library;
    if (api == null || !loggedIn || offline) {
      throw const AppFailure(AppMessage.connectToTheServerToSaveThis);
    }
    if (creatingServerPlaylist || serverPlaylist.saving) {
      throw const AppFailure(AppMessage.waitForTheCurrentOperationToFinish);
    }
    final identity = libraryIdentity;
    bool current() => identical(library, api) && libraryIdentity == identity;
    final entries = queue.entries;
    final tracks = entries.map((entry) => entry.track).toList();
    final oldServer = serverPlaylist.item?.id;
    final oldLocal = loadedLocalPlaylistId;
    creatingServerPlaylist = true;
    notifyListeners();
    try {
      LibraryItem item;
      var verified = true;
      try {
        item = await playlistMutations.create(
          api,
          name,
          tracks,
          isCurrent: current,
        );
      } on CreatedPlaylistUnverified catch (error) {
        item = error.item;
        verified = false;
      }
      if (!current()) return;
      _catalog.invalidateKey('playlists');
      _cache['playlists'] = [
        ...?_cache['playlists']?.where((entry) => entry.id != item.id),
        item,
      ]..sort(compareItems);
      if (verified) _cache[item.id] = List.unmodifiable(tracks);
      if (verified &&
          identical(entries, queue.entries) &&
          serverPlaylist.item?.id == oldServer &&
          loadedLocalPlaylistId == oldLocal) {
        loadedLocalPlaylistId = null;
        await serverPlaylist.open(
          api,
          item,
          baseline: tracks.map((t) => t.id).toList(),
        );
      }
      if (!current()) return;
      serverPlaylistRevision++;
      catalogRevision++;
      _trackCounts.invalidate();
      countRevision++;
      notifyListeners();
      await _saveCatalog();
      if (!current()) return;
      await save();
      if (!current()) return;
      message(
        verified
            ? AppMessage.serverPlaylistSaved(item.name)
            : AppMessage.playlistCreatedCheckContents(item.name),
      );
    } finally {
      creatingServerPlaylist = false;
      notifyListeners();
    }
  }

  Future<void> deletePlaylist(LibraryItem item) async {
    if (!item.isPlaylist) {
      throw const AppFailure(AppMessage.onlyPlaylistsCanBeDeleted);
    }
    if (item.isLocalPlaylist) {
      await deleteLocalPlaylist(item);
      return;
    }
    final api = library;
    if (api == null || !loggedIn || offline) {
      throw const AppFailure(AppMessage.noServerConnection);
    }
    if (serverPlaylist.saving || creatingServerPlaylist) {
      throw const AppFailure(AppMessage.waitForTheCurrentOperationToFinish);
    }
    final identity = libraryIdentity;
    bool current() => identical(library, api) && libraryIdentity == identity;
    await api.deletePlaylist(item, isCurrent: current);
    if (!current()) return;
    _catalog.invalidateKey('playlists');
    _catalog.invalidateKey(item.id);
    _catalog.invalidateKey('recursive:${item.id}');
    _cache.remove(item.id);
    _cache.remove('recursive:${item.id}');
    _catalog.removeItem(item.id);
    if (serverPlaylist.item?.id == item.id) serverPlaylist.clear();
    final pathIndex = browse.path.indexWhere((entry) => entry.id == item.id);
    if (pathIndex >= 0) {
      browse = BrowseLocation(
        tab: browse.tab,
        path: browse.path.take(pathIndex).toList(),
      );
    }
    serverPlaylistRevision++;
    catalogRevision++;
    _trackCounts.invalidate();
    countRevision++;
    notifyListeners();
    await _saveCatalog();
    if (current()) await save();
  }

  Future<void> saveQueueToServer({bool overwriteChanged = false}) async {
    final api = library;
    final target = serverPlaylist.item;
    if (!loggedIn || offline || api == null || target == null) {
      throw const AppFailure(AppMessage.connectToTheServerToSaveThis);
    }
    final snapshot = queue.entries.map((entry) => entry.track).toList();
    await serverPlaylist.save(
      api,
      snapshot,
      overwriteChanged: overwriteChanged,
    );
    if (library == api) {
      _catalog.invalidateKey(target.id);
      _catalog.invalidateKey('recursive:${target.id}');
      _cache.remove(target.id);
      _cache.remove('recursive:${target.id}');
      _trackCounts.invalidate();
      countRevision++;
      serverPlaylistRevision++;
      await _saveCatalog();
      await save();
      notifyListeners();
    }
    message(AppMessage.serverPlaylistSaved(target.name));
  }

  PlaylistEditSession editServerPlaylist(LibraryItem source) {
    final api = library;
    final identity = libraryIdentity;
    bool current() => libraryIdentity == identity && identical(library, api);
    void ensureCurrent() {
      if (!current()) {
        throw const AppFailure(AppMessage.theAccountHasChangedOpenThePlaylist);
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
        final list = await freshChildren(source);
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
        message(AppMessage.localPlaylistSaved(item.name));
        return item;
      },
      serverSaved: () async {
        ensureCurrent();
        _catalog.invalidateKey(source.id);
        _catalog.invalidateKey('recursive:${source.id}');
        _cache.remove(source.id);
        _cache.remove('recursive:${source.id}');
        _trackCounts.invalidate();
        countRevision++;
        serverPlaylistRevision++;
        await _saveCatalog();
        if (current()) notifyListeners();
        message(AppMessage.serverPlaylistSaved(source.name));
      },
    );
  }

  Future<void> deleteLocalPlaylist(LibraryItem item) async {
    await localPlaylists.delete(item.id);
    if (loadedLocalPlaylistId == item.id) loadedLocalPlaylistId = null;
    localRevision++;
    await save();
    notifyListeners();
    message(AppMessage.localPlaylistDeleted);
  }

  void _cancelGroupPreparation() {
    if (preparingGroup == null) return;
    preparingGroup = null;
    _preparingRequest = null;
    resolvingGroup = false;
    groupPreparationError = null;
    failedGroup = null;
    notifyListeners();
  }

  Future<void> selectIndex(int index) async {
    if (index < 0 || index >= queue.entries.length) return;
    _groupPlayRequest++;
    _cancelGroupPreparation();
    queue.select(queue.entries[index].id);
    _restoredPosition = 0;
    wantsPlayback = true;
    await _start(queue.current);
  }

  Future<void> resume() async {
    _cancelGroupPreparation();
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
    _cancelGroupPreparation();
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
    if (!automatic) {
      _groupPlayRequest++;
      _cancelGroupPreparation();
    }
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
    _cancelGroupPreparation();
    _groupPlayRequest++;
    final entry = queue.previous();
    if (entry == null) return;
    _restoredPosition = 0;
    wantsPlayback = true;
    await _start(entry);
  }

  Future<void> _start(QueueEntry? first, {Duration position = Duration.zero}) =>
      _playback.start(first, position: position);
  void _playbackError(Object error) => _playback.onError(error);

  void _reportUnavailable(LibraryItem track) {
    _skipCount++;
    final text = AppMessage.trackIsUnavailable(track.title);
    message(text);
    unawaited(
      notifications
          .show(
            id: 41,
            title: AppMessage.skippedTracks(_skipCount).text,
            body: text.text,
            notificationDetails: NotificationDetails(
              android: AndroidNotificationDetails(
                'unavailable-tracks',
                AppMessage.unavailableTracks.text,
                channelDescription:
                    AppMessage.notificationsAboutSkippedTracks.text,
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
    unawaited(_persist('browse_$_stateKey', browse.toJson()));
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
              ? AppMessage.importedTracks(count)
              : AppMessage.noSupportedAudioFilesInThisLocation,
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

  void message(Object text) {
    messages.add(text.toString());
  }

  static String friendly(Object error) => error is PlatformException
      ? switch (error.code) {
          'busy' => L10n.current.filePickerBusy,
          'unavailable' => L10n.current.filePickerUnavailable,
          'import_failed' => L10n.current.importFailed,
          'cancelled' => L10n.current.importCancelled,
          _ => L10n.current.couldNotCompleteTheOperationCheckYour,
        }
      : error is AppMessage
      ? error.text
      : error is LocalizedFormatException
      ? error.message
      : error is AppFailure
      ? error.message
      : AppMessage.couldNotCompleteTheOperationCheckYour.text;

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
    } on Object catch (error) {
      Diagnostics.record('controller-recovery', error);
      // A volume-control error is not a missing/corrupt audio file. In
      // particular it must never invalidate an existing offline download.
      message(AppMessage.couldNotApplyVolumeNormalization);
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
    notifyListeners();
    await downloads!.setCellular(value);
    await save();
    notifyListeners();
  }

  Future<void> removeDownloadedTrack(LibraryItem track) async {
    final manager = downloads;
    if (manager == null || !loggedIn) {
      throw const AppFailure(AppMessage.theAccountHasChanged);
    }
    if (queue.current?.track.id == track.id) await releaseLocalAudio();
    if (!identical(downloads, manager)) {
      throw const AppFailure(AppMessage.theAccountHasChanged);
    }
    await manager.removeTrack(track.id);
    message(AppMessage.trackRemovedFromThisDevice);
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

  Future<void> _releaseStream() => _playback.releaseStream();

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
    final entry = queue.current;
    if (entry == null) return;
    final generation = _operation;
    final duration =
        (hasLoadedCurrent ? audio.player.duration : null) ??
        Duration(milliseconds: entry.track.durationMs);
    final milliseconds = value.inMilliseconds.clamp(
      0,
      duration > Duration.zero ? duration.inMilliseconds : 1 << 53,
    );
    final target = Duration(milliseconds: milliseconds);
    if (hasLoadedCurrent) {
      await audio.player.seek(target);
    } else {
      _restoredPosition = milliseconds;
    }
    if (queue.current?.id != entry.id || generation != _operation) return;
    changed();
  }

  Future<void> setMobileStreaming(bool value) async {
    allowMobileStreaming = value;
    notifyListeners();
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

  DownloadActivity? get downloadActivity => downloads?.activity;

  Future<void> continueDownloads() async {
    final manager = downloads;
    if (manager == null) return;
    final connection = await network.current();
    if (!identical(manager, downloads)) return;
    manager.setNetwork(connection);
    await manager.retryPending(manual: true);
  }

  Future<void> resumeTransfers() async {
    if (!loggedIn) return;
    try {
      final manager = downloads!;
      manager.setNetwork(await network.current());
      if (!identical(manager, downloads)) return;
      await manager.reconcile();
      await manager.retryPending();
    } on Object catch (error) {
      message(friendly(error));
    }
    if (waitingForNetwork && wantsPlayback && _streamAllowed) {
      unawaited(resume());
    }
  }

  @override
  void dispose() {
    _serverChecksClosed = true;
    languages.removeListener(_languageChanged);
    languages.dispose();
    _catalog.dispose();
    _catalogSaveTimer?.cancel();
    audio.cancelGainAdjustment();
    _trackCounts.dispose();
    _serverRetry?.cancel();
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

Map<String, dynamic> _catalogSnapshot(Map<String, List<LibraryItem>> cache) => {
  for (final entry in cache.entries)
    entry.key: entry.value.map((item) => item.toJson()).toList(),
};

Map<String, List<LibraryItem>> _decodeCatalogSnapshot(
  Map<String, dynamic> saved,
) => {
  for (final entry in saved.entries)
    entry.key: List<LibraryItem>.unmodifiable(decodeItems(entry.value)),
};
