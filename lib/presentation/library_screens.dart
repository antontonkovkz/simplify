import '../l10n/l10n.dart';
import 'dart:async';

import 'package:flutter/material.dart';

import '../application/app_controller.dart';
import '../domain/library_item.dart';
import '../domain/track_search_index.dart';
import 'actions.dart';
import 'player_screens.dart';
import 'settings_screen.dart';
import 'widgets.dart';
import 'track_count_badge.dart';
import 'playlist_editor_screen.dart';
import 'play_group_action.dart';
import 'catalog_update_status.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.app});
  final AppController app;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with RouteAware {
  int _tab = 0;
  late Future<List<LibraryItem>> _items;
  final Map<int, Future<List<LibraryItem>>> _tabItems = {};
  bool _wasRefreshing = false;
  String? _shownChanges;
  Object? _changesSnapshot;
  String _changesSignature = '';
  int _localRevision = 0;
  int _catalogRevision = 0;
  bool _filePlaylistsExpanded = false;
  late String _playlistIdentity;
  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    _playlistIdentity = app.libraryIdentity;
    _tab = app.browse.tab;
    _items = app.root(_tab == 1);
    _tabItems[_tab] = _items;
    app.addListener(_changed);
    final path = List<LibraryItem>.of(app.browse.path);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final navigator = Navigator.of(context);
      for (var i = 0; i < path.length; i++) {
        if (path[i].isLocalPlaylist &&
            app.localPlaylists.item(path[i].id) == null) {
          break;
        }
        if (path[i].isLocal && !app.localMusic.contains(path[i].id)) break;
        navigator.push(
          slideRoute(
            LibraryScreen(
              app: app,
              parent: path[i],
              ancestors: path.take(i).toList(),
            ),
          ),
        );
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) libraryRouteObserver.subscribe(this, route);
  }

  @override
  void didPopNext() {
    app.setBrowse(_tab, []);
    final cached = app.peekRoot(_tab == 1);
    if (cached != null) {
      setState(() {
        _items = Future.value(cached);
        _tabItems[_tab] = _items;
      });
    }
  }

  void _changed() {
    if (!mounted) return;
    if (_playlistIdentity != app.libraryIdentity) {
      _playlistIdentity = app.libraryIdentity;
      _filePlaylistsExpanded = false;
      _tabItems.clear();
    }
    if ((_wasRefreshing && !app.refreshing && app.loggedIn) ||
        _localRevision != app.localRevision) {
      _localRevision = app.localRevision;
      for (final tab in _tabItems.keys.toList()) {
        _tabItems[tab] = app.root(tab == 1);
      }
      _items = _tabItems[_tab] ?? app.root(_tab == 1);
    }
    if (_catalogRevision != app.catalogRevision) {
      _catalogRevision = app.catalogRevision;
      for (final tab in _tabItems.keys.toList()) {
        final cached = app.peekRoot(tab == 1);
        if (cached != null) _tabItems[tab] = Future.value(cached);
      }
      _items = _tabItems[_tab] ?? _items;
    }
    _tabItems[_tab] = _items;
    _wasRefreshing = app.refreshing;
    if (!identical(_changesSnapshot, app.pendingChanges)) {
      _changesSnapshot = app.pendingChanges;
      _changesSignature = app.pendingChanges
          .map((change) => change.after.fingerprint)
          .join();
    }
    final signature = _changesSignature;
    if (signature.isNotEmpty &&
        signature != _shownChanges &&
        ModalRoute.of(context)?.isCurrent == true) {
      _shownChanges = signature;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(showChanges(context, app));
      });
    }
    setState(() {});
  }

  @override
  void dispose() {
    libraryRouteObserver.unsubscribe(this);
    app.removeListener(_changed);
    super.dispose();
  }

  Future<void> _refresh() async {
    _shownChanges = null;
    await app.refresh();
    if (mounted) {
      setState(() {
        _items = app.root(_tab == 1);
        _tabItems[_tab] = _items;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        _tab == 0 ? context.l10n.collections : context.l10n.playlists,
      ),
      actions: [
        _LibraryFilterButton(app: app),
        IconButton(
          tooltip: context.l10n.searchMusic,
          icon: const Icon(Icons.search_rounded),
          onPressed: () =>
              Navigator.push(context, slideRoute(SearchScreen(app: app))),
        ),
        IconButton(
          tooltip: context.l10n.settings,
          icon: const Icon(Icons.tune_rounded),
          onPressed: () =>
              Navigator.push(context, slideRoute(SettingsScreen(app: app))),
        ),
      ],
    ),
    body: Column(
      children: [
        CatalogUpdateStatus(
          app: app,
          cacheKey: _tab == 1 ? 'playlists' : 'collections',
        ),
        _LibraryStatus(app: app),
        AnimatedSize(
          duration: motionDuration,
          child: app.pendingChanges.isEmpty
              ? const SizedBox.shrink()
              : _ChangesBanner(app: app),
        ),
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: [
              for (var tab = 0; tab < 2; tab++)
                if (_tabItems.containsKey(tab))
                  RefreshIndicator(
                    onRefresh: _refresh,
                    child: FutureBuilder(
                      future: _tabItems[tab],
                      initialData: app.peekRoot(tab == 1),
                      builder: (context, snapshot) => _listState(
                        context,
                        snapshot,
                        app: app,
                        filenames: false,
                        playlistGroups: tab == 1,
                        filePlaylistsExpanded: _filePlaylistsExpanded,
                        onToggleFilePlaylists: () => setState(() {
                          _filePlaylistsExpanded = !_filePlaylistsExpanded;
                        }),
                        onTap: (item, items) => Navigator.push(
                          context,
                          slideRoute(LibraryScreen(app: app, parent: item)),
                        ),
                      ),
                    ),
                  )
                else
                  const SizedBox.shrink(),
            ],
          ),
        ),
        MiniPlayer(app: app, bottomSafeArea: false),
      ],
    ),
    bottomNavigationBar: NavigationBar(
      height: 60,
      labelPadding: EdgeInsets.zero,
      selectedIndex: _tab,
      onDestinationSelected: (value) {
        app.setBrowse(value, []);
        setState(() {
          _tab = value;
          _items = _tabItems.putIfAbsent(_tab, () => app.root(_tab == 1));
        });
      },
      destinations: [
        NavigationDestination(
          icon: Icon(Icons.folder_outlined),
          selectedIcon: Icon(Icons.folder_rounded),
          label: context.l10n.collections,
        ),
        NavigationDestination(
          icon: Icon(Icons.queue_music_rounded),
          label: context.l10n.playlists,
        ),
      ],
    ),
  );
}

class _LibraryFilterButton extends StatelessWidget {
  const _LibraryFilterButton({required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: context.l10n.onDevice,
    isSelected: app.onlyDownloaded,
    icon: const Icon(Icons.offline_pin_outlined),
    selectedIcon: const Icon(Icons.offline_pin_rounded),
    onPressed: () => app.setOnlyDownloaded(!app.onlyDownloaded),
  );
}

class _LibraryStatus extends StatelessWidget {
  const _LibraryStatus({required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) {
    final visible =
        app.offline || app.onlyDownloaded || app.refreshing || app.importing;
    return AnimatedSize(
      duration: motionDuration,
      alignment: Alignment.topCenter,
      child: !visible
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(left: 16, right: 8, bottom: 4),
              child: Row(
                children: [
                  if ((app.refreshing && !app.offline) || app.importing)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  Expanded(
                    child: Text(
                      app.importing
                          ? context.l10n.importingMusic
                          : app.offline
                          ? context.l10n.offlineMusicOnDevice
                          : app.refreshing
                          ? context.l10n.refreshingLibrary
                          : context.l10n.onDeviceOnly,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (app.onlyDownloaded)
                    IconButton(
                      tooltip: context.l10n.resetFilter,
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () => app.setOnlyDownloaded(false),
                    ),
                ],
              ),
            ),
    );
  }
}

class _ChangesBanner extends StatelessWidget {
  const _ChangesBanner({required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 20),
    child: TextButton.icon(
      onPressed: () => showChanges(context, app),
      icon: const Icon(Icons.sync_rounded),
      label: Text(
        context.l10n.updateDownloads((app.pendingChanges.length).toString()),
      ),
    ),
  );
}

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.app,
    required this.parent,
    this.ancestors = const [],
  });
  final AppController app;
  final LibraryItem parent;
  final List<LibraryItem> ancestors;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> with RouteAware {
  bool _wasRefreshing = false;
  int _localRevision = 0;
  int _catalogRevision = 0;
  int _serverPlaylistRevision = 0;
  late Future<List<LibraryItem>> _items = widget.app.children(widget.parent);
  AppController get app => widget.app;
  @override
  void initState() {
    super.initState();
    app.addListener(_libraryChanged);
    _localRevision = app.localRevision;
    _serverPlaylistRevision = app.serverPlaylistRevision;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) libraryRouteObserver.subscribe(this, route);
  }

  void _remember() => app.setBrowse(widget.parent.isPlaylist ? 1 : 0, [
    ...widget.ancestors,
    widget.parent,
  ]);
  @override
  void didPush() => _remember();
  @override
  void didPopNext() => _remember();

  void _libraryChanged() {
    if (((_wasRefreshing && !app.refreshing && app.loggedIn) ||
            (widget.parent.isPlaylist &&
                _serverPlaylistRevision != app.serverPlaylistRevision) ||
            ((widget.parent.isLocal || widget.parent.isLocalPlaylist) &&
                _localRevision != app.localRevision)) &&
        mounted) {
      setState(() {
        _items = app.freshChildren(widget.parent);
      });
    }
    if (mounted && _catalogRevision != app.catalogRevision) {
      _catalogRevision = app.catalogRevision;
      final cached = app.peekChildren(widget.parent);
      if (cached != null) {
        setState(() {
          _items = Future.value(cached);
        });
      }
    }
    _wasRefreshing = app.refreshing;
    _localRevision = app.localRevision;
    _serverPlaylistRevision = app.serverPlaylistRevision;
  }

  @override
  void dispose() {
    libraryRouteObserver.unsubscribe(this);
    app.removeListener(_libraryChanged);
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _items = app.freshChildren(widget.parent);
    });
    try {
      await _items;
    } on Object catch (_) {
      /* FutureBuilder displays retry. */
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        toolbarHeight:
            (MediaQuery.textScalerOf(context).scale(22) * 1.3 +
                    MediaQuery.textScalerOf(context).scale(14) * 1.3 +
                    4)
                .clamp(56, double.infinity),
        title: Semantics(
          hint: context.l10n.touchAndHoldToOpenActions,
          onLongPress: () => itemMenu(context, app, widget.parent),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () => itemMenu(context, app, widget.parent),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.parent.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.ancestors.isNotEmpty
                            ? widget.ancestors
                                  .skip(
                                    (widget.ancestors.length - 2).clamp(
                                      0,
                                      widget.ancestors.length,
                                    ),
                                  )
                                  .map((item) => item.displayName)
                                  .join(' / ')
                            : widget.parent.isLocal
                            ? context.l10n.onDevice
                            : widget.parent.isPlaylist
                            ? (widget.parent.isLocalPlaylist
                                  ? context.l10n.localPlaylist
                                  : context.l10n.serverPlaylist)
                            : widget.parent.kind == ItemKind.collection
                            ? context.l10n.collection
                            : context.l10n.folder,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    TrackCountBadge(app: app, item: widget.parent),
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          if (widget.parent.isPlaylist && !widget.parent.isLocalPlaylist)
            IconButton(
              tooltip: context.l10n.editPlaylist,
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => Navigator.push(
                context,
                slideRoute(
                  PlaylistEditorScreen(app: app, source: widget.parent),
                ),
              ),
            ),
          if (widget.parent.id == 'local:root')
            IconButton(
              tooltip: context.l10n.addMusicFromFiles2,
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: app.importing
                  ? null
                  : () => importMusicMenu(context, app),
            ),
          _LibraryFilterButton(app: app),
          IconButton(
            tooltip: context.l10n.search,
            icon: const Icon(Icons.search_rounded),
            onPressed: () => Navigator.push(
              context,
              slideRoute(SearchScreen(app: app, scope: widget.parent)),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          CatalogUpdateStatus(app: app, cacheKey: widget.parent.id),
          _LibraryStatus(app: app),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                await app.refresh();
                await _reload();
              },
              child: FutureBuilder(
                future: _items,
                initialData: app.peekChildren(widget.parent),
                builder: (context, snapshot) => _listState(
                  context,
                  snapshot,
                  app: app,
                  filenames: !widget.parent.isPlaylist,
                  onTap: (item, items) {
                    if (item.isTrack) {
                      final tracks = items.where((e) => e.isTrack).toList();
                      unawaited(
                        perform(
                          app,
                          () => app.playTracks(
                            tracks,
                            start: tracks.indexOf(item),
                            serverPlaylistSource:
                                widget.parent.isPlaylist &&
                                    !widget.parent.isLocalPlaylist
                                ? widget.parent
                                : null,
                            localPlaylistId: widget.parent.isLocalPlaylist
                                ? widget.parent.id
                                : null,
                          ),
                        ),
                      );
                    } else {
                      Navigator.push(
                        context,
                        slideRoute(
                          LibraryScreen(
                            app: app,
                            parent: item,
                            ancestors: [...widget.ancestors, widget.parent],
                          ),
                        ),
                      );
                    }
                  },
                ),
              ),
            ),
          ),
          MiniPlayer(app: app),
        ],
      ),
    ),
  );
}

enum _LibrarySection { server, local, files }

sealed class _LibraryRow {
  const _LibraryRow();
  String get key;
  LibraryItem? get item => null;
}

class _LibraryTrackRow extends _LibraryRow {
  const _LibraryTrackRow(this.key, this.item);
  @override
  final String key;
  @override
  final LibraryItem item;
}

class _LibraryHeader extends _LibraryRow {
  const _LibraryHeader(this.section);
  final _LibrarySection section;
  @override
  String get key => 'header:${section.name}';
}

Widget _listState(
  BuildContext context,
  AsyncSnapshot<List<LibraryItem>> snapshot, {
  required AppController app,
  required bool filenames,
  bool playlistGroups = false,
  bool filePlaylistsExpanded = false,
  VoidCallback? onToggleFilePlaylists,
  required void Function(LibraryItem, List<LibraryItem>) onTap,
}) {
  final loading =
      snapshot.connectionState != ConnectionState.done && !snapshot.hasData;
  final hasRows = snapshot.data?.isNotEmpty == true;
  final state = loading
      ? 'loading'
      : snapshot.hasError
      ? 'error'
      : hasRows
      ? 'rows'
      : 'empty';
  return AnimatedSwitcher(
    duration: motionDuration,
    child: KeyedSubtree(
      key: ValueKey(state),
      child: _listContent(
        context,
        snapshot,
        app: app,
        filenames: filenames,
        playlistGroups: playlistGroups,
        filePlaylistsExpanded: filePlaylistsExpanded,
        onToggleFilePlaylists: onToggleFilePlaylists,
        onTap: onTap,
      ),
    ),
  );
}

Widget _listContent(
  BuildContext context,
  AsyncSnapshot<List<LibraryItem>> snapshot, {
  required AppController app,
  required bool filenames,
  bool playlistGroups = false,
  bool filePlaylistsExpanded = false,
  VoidCallback? onToggleFilePlaylists,
  required void Function(LibraryItem, List<LibraryItem>) onTap,
}) {
  return _LibraryContents(
    snapshot: snapshot,
    app: app,
    filenames: filenames,
    playlistGroups: playlistGroups,
    filePlaylistsExpanded: filePlaylistsExpanded,
    onToggleFilePlaylists: onToggleFilePlaylists,
    onTap: onTap,
  );
}

class _LibraryContents extends StatefulWidget {
  const _LibraryContents({
    required this.snapshot,
    required this.app,
    required this.filenames,
    required this.playlistGroups,
    required this.filePlaylistsExpanded,
    this.onToggleFilePlaylists,
    required this.onTap,
  });
  final AsyncSnapshot<List<LibraryItem>> snapshot;
  final AppController app;
  final bool filenames, playlistGroups, filePlaylistsExpanded;
  final VoidCallback? onToggleFilePlaylists;
  final void Function(LibraryItem, List<LibraryItem>) onTap;
  @override
  State<_LibraryContents> createState() => _LibraryContentsState();
}

class _LibraryContentsState extends State<_LibraryContents> {
  Object? _stamp;
  Object? _rowsStamp;
  List<LibraryItem> _items = const [];
  List<_LibraryRow> _rows = const [];
  int _fileCount = 0;

  @override
  Widget build(BuildContext context) =>
      AnimatedSwitcher(duration: motionDuration, child: _buildContent(context));

  Widget _buildContent(BuildContext context) {
    final snapshot = widget.snapshot;
    final app = widget.app;
    final filenames = widget.filenames;
    final playlistGroups = widget.playlistGroups;
    final filePlaylistsExpanded = widget.filePlaylistsExpanded;
    final onToggleFilePlaylists = widget.onToggleFilePlaylists;
    final onTap = widget.onTap;
    if (snapshot.connectionState != ConnectionState.done && !snapshot.hasData) {
      return const Center(child: CircularProgressIndicator());
    }
    if (snapshot.hasError) {
      return EmptyState(
        context.l10n.couldNotOpenTheLibrary,
        subtitle: AppController.friendly(snapshot.error!),
        icon: Icons.cloud_off_rounded,
      );
    }
    final all = snapshot.data ?? [];
    final stamp = (
      all,
      app.onlyDownloaded,
      app.onlyDownloaded ? app.downloads?.completedTracks : null,
      app.localRevision,
      playlistGroups,
      filePlaylistsExpanded,
    );
    if (_stamp != stamp) {
      _stamp = stamp;
      _items = app.onlyDownloaded ? all.where(app.isDownloaded).toList() : all;
    }
    final items = _items;
    if (items.isEmpty) {
      return EmptyState(
        context.l10n.nothingHereYet,
        subtitle: app.onlyDownloaded
            ? context.l10n.downloadMusicOrTurnOffTheOn
            : null,
        icon: Icons.folder_open_rounded,
      );
    }
    if (_rowsStamp != stamp) {
      _rowsStamp = stamp;
      final keys = occurrenceKeys(items);
      final rows = List<_LibraryRow>.generate(
        items.length,
        (i) => _LibraryTrackRow(keys[i], items[i]),
      );
      final files = playlistGroups
          ? rows.where((e) => e.item!.isFilePlaylist).toList()
          : <_LibraryRow>[];
      if (playlistGroups) {
        final server = rows
            .where((e) => !e.item!.isLocalPlaylist && !e.item!.isFilePlaylist)
            .toList();
        final local = rows.where((e) => e.item!.isLocalPlaylist).toList();
        rows.clear();
        if (server.isNotEmpty) {
          rows.addAll([
            const _LibraryHeader(_LibrarySection.server),
            ...server,
          ]);
        }
        if (local.isNotEmpty) {
          rows.addAll([const _LibraryHeader(_LibrarySection.local), ...local]);
        }
      }
      if (files.isNotEmpty) {
        rows.add(const _LibraryHeader(_LibrarySection.files));
        if (filePlaylistsExpanded) rows.addAll(files);
      }
      _rows = List.unmodifiable(rows);
      _fileCount = files.length;
    }
    return AnimatedRows<_LibraryRow>(
      physics: const AlwaysScrollableScrollPhysics(),
      items: _rows,
      idOf: (e) => e.key,
      builder: (context, row, _) =>
          row is _LibraryHeader && row.section == _LibrarySection.files
          ? ListTile(
              key: const ValueKey('file-playlists-toggle'),
              title: Text(context.l10n.filePlaylists),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('$_fileCount'),
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: filePlaylistsExpanded ? .5 : 0,
                    duration: motionDuration,
                    child: const Icon(Icons.expand_more_rounded),
                  ),
                ],
              ),
              onTap: onToggleFilePlaylists,
            )
          : row is _LibraryHeader
          ? Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
              child: Text(
                row.section == _LibrarySection.server
                    ? context.l10n.serverPlaylists
                    : context.l10n.localPlaylists,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            )
          : ItemTile(
              item: row.item!,
              unavailable: app.isUnavailable(row.item!),
              filenames: filenames,
              downloaded: row.item!.isTrack && app.isDownloaded(row.item!),
              progress: app.downloads?.progress[row.item!.id],
              active:
                  row.item!.isTrack &&
                  row.item!.id == app.queue.current?.track.id,
              onTap: () => onTap(row.item!, all),
              onMenu: () => itemMenu(context, app, row.item!),
              onPlay: row.item!.isTrack
                  ? null
                  : () => playGroupAndOpenQueue(context, app, row.item!),
              trailing: row.item!.isTrack
                  ? null
                  : TrackCountBadge(app: app, item: row.item!),
            ),
    );
  }
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, required this.app, this.scope});
  final AppController app;
  final LibraryItem? scope;
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  List<LibraryItem> _all = [];
  List<LibraryItem> _results = [];
  bool _loading = true;
  String _query = '';
  Object? _error;
  Timer? _debounce;
  int _searchRevision = 0;
  TrackSearchIndex? _searchIndex;
  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      _all = await app.searchTracks(widget.scope);
      if (!mounted) return;
      _searchIndex = TrackSearchIndex(_all);
      if (mounted) {
        setState(() {
          _loading = false;
        });
        unawaited(_filter());
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error;
        });
      }
    }
  }

  Future<void> _filter() async {
    final revision = ++_searchRevision;
    final results = _query.trim().isEmpty
        ? <LibraryItem>[]
        : await _searchIndex!.find(_query);
    if (mounted && revision == _searchRevision) {
      setState(() {
        _results = results;
      });
    }
  }

  void _queryChanged(String value) {
    _query = value;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      if (mounted) unawaited(_filter());
    });
  }

  Future<void> _play(LibraryItem track) async {
    if (widget.scope?.isPlaylist == true) {
      await perform(
        app,
        () => app.playTracks(
          _all,
          start: _all.indexOf(track),
          serverPlaylistSource: widget.scope!.isLocalPlaylist
              ? null
              : widget.scope,
          localPlaylistId: widget.scope!.isLocalPlaylist
              ? widget.scope!.id
              : null,
        ),
      );
      return;
    }
    final choice = await appDialog<int>(
      context,
      (context) => SimpleDialog(
        title: Text(context.l10n.whereWouldYouLikeToContinue),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 0),
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Text(context.l10n.inThisTrackSFolder),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 1),
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Text(context.l10n.inSearchResults),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context),
            child: Text(context.l10n.cancel),
          ),
        ],
      ),
    );
    if (choice == null) return;
    await perform(app, () async {
      if (choice == 1 || track.parentId == null) {
        final visible = _results
            .where((t) => !app.onlyDownloaded || app.isDownloaded(t))
            .toList();
        await app.playTracks(visible, start: visible.indexOf(track));
      } else {
        final parent = LibraryItem(
          id: track.parentId!,
          name: context.l10n.folder,
          kind: ItemKind.folder,
          path: track.path.substring(
            0,
            track.path
                .replaceAll('\\', '/')
                .lastIndexOf('/')
                .clamp(0, track.path.length),
          ),
        );
        final tracks = await app.tracks(parent, recursive: false);
        final index = tracks.indexWhere((e) => e.id == track.id);
        await app.playTracks(tracks, start: index < 0 ? 0 : index);
      }
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: TextField(
          autofocus: true,
          decoration: InputDecoration(
            hintText: context.l10n.fileNameArtistOrTrack,
            border: InputBorder.none,
          ),
          onChanged: _queryChanged,
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.scope?.displayName ?? context.l10n.allMusicCollections,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: motionDuration,
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? EmptyState(
                      AppController.friendly(_error!),
                      icon: Icons.cloud_off_rounded,
                    )
                  : _results.isEmpty
                  ? EmptyState(
                      _query.isEmpty
                          ? context.l10n.findYourMusic
                          : context.l10n.noResults,
                      icon: Icons.search_rounded,
                    )
                  : _listState(
                      context,
                      AsyncSnapshot.withData(ConnectionState.done, _results),
                      app: app,
                      filenames: widget.scope?.isPlaylist != true,
                      onTap: (track, _) => _play(track),
                    ),
            ),
          ),
          MiniPlayer(app: app),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    _searchIndex?.dispose();
    _debounce?.cancel();
    super.dispose();
  }
}
