import 'dart:async';

import 'package:flutter/material.dart';

import '../application/app_controller.dart';
import '../domain/library_item.dart';
import '../domain/library_search.dart';
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
  bool _wasRefreshing = false;
  String? _shownChanges;
  int _localRevision = 0;
  int _catalogRevision = 0;
  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    _tab = app.browse.tab;
    _items = app.root(_tab == 1);
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
  void didPopNext() => app.setBrowse(_tab, []);

  void _changed() {
    if (!mounted) return;
    if ((_wasRefreshing && !app.refreshing && app.loggedIn) ||
        _localRevision != app.localRevision) {
      _localRevision = app.localRevision;
      _items = app.root(_tab == 1);
    }
    if (_catalogRevision != app.catalogRevision) {
      _catalogRevision = app.catalogRevision;
      final cached = app.peekRoot(_tab == 1);
      if (cached != null) _items = Future.value(cached);
    }
    _wasRefreshing = app.refreshing;
    final signature = app.pendingChanges.map((c) => c.after.fingerprint).join();
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
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_tab == 0 ? 'Коллекции' : 'Плейлисты'),
      actions: [
        _LibraryFilterButton(app: app),
        IconButton(
          tooltip: 'Поиск по музыке',
          icon: const Icon(Icons.search_rounded),
          onPressed: () =>
              Navigator.push(context, slideRoute(SearchScreen(app: app))),
        ),
        IconButton(
          tooltip: 'Настройки',
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
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: FutureBuilder(
              future: _items,
              initialData: app.peekRoot(_tab == 1),
              builder: (context, snapshot) => _listState(
                context,
                snapshot,
                app: app,
                filenames: false,
                playlistGroups: _tab == 1,
                onTap: (item, items) => Navigator.push(
                  context,
                  slideRoute(LibraryScreen(app: app, parent: item)),
                ),
              ),
            ),
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
          _items = app.root(_tab == 1);
        });
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.folder_outlined),
          selectedIcon: Icon(Icons.folder_rounded),
          label: 'Коллекции',
        ),
        NavigationDestination(
          icon: Icon(Icons.queue_music_rounded),
          label: 'Плейлисты',
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
    tooltip: 'На устройстве',
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
                  if (app.refreshing || app.importing)
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
                          ? 'Импортируем музыку…'
                          : app.refreshing
                          ? 'Обновляем библиотеку…'
                          : app.offline
                          ? 'Нет сети · музыка на устройстве'
                          : 'Только на устройстве',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (app.onlyDownloaded)
                    IconButton(
                      tooltip: 'Сбросить фильтр',
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
      label: Text('Обновить загрузки: ${app.pendingChanges.length}'),
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
    } catch (_) {
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
          hint: 'Удерживайте, чтобы открыть контекстное меню',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () => itemMenu(context, app, widget.parent),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.parent.name,
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
                                  .map((item) => item.name)
                                  .join(' / ')
                            : widget.parent.isLocal
                            ? 'На устройстве'
                            : widget.parent.isPlaylist
                            ? (widget.parent.isLocalPlaylist
                                  ? 'Локальный плейлист'
                                  : 'Серверный плейлист')
                            : widget.parent.kind == ItemKind.collection
                            ? 'Коллекция'
                            : 'Папка',
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
              tooltip: 'Редактировать плейлист',
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
              tooltip: 'Добавить музыку из Файлов',
              icon: const Icon(Icons.create_new_folder_outlined),
              onPressed: app.importing
                  ? null
                  : () => importMusicMenu(context, app),
            ),
          _LibraryFilterButton(app: app),
          IconButton(
            tooltip: 'Поиск',
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

class _LibraryRow {
  const _LibraryRow(this.key, this.item, this.index);
  final String key;
  final LibraryItem? item;
  final int index;
}

Widget _listState(
  BuildContext context,
  AsyncSnapshot<List<LibraryItem>> snapshot, {
  required AppController app,
  required bool filenames,
  bool playlistGroups = false,
  required void Function(LibraryItem, List<LibraryItem>) onTap,
}) {
  final loading =
      snapshot.connectionState != ConnectionState.done && !snapshot.hasData;
  final hasRows = (snapshot.data ?? []).any(
    (item) => !app.onlyDownloaded || app.isDownloaded(item),
  );
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
  required void Function(LibraryItem, List<LibraryItem>) onTap,
}) {
  if (snapshot.connectionState != ConnectionState.done && !snapshot.hasData) {
    return const Center(child: CircularProgressIndicator());
  }
  if (snapshot.hasError) {
    return EmptyState(
      'Не удалось открыть библиотеку',
      subtitle: AppController.friendly(snapshot.error!),
      icon: Icons.cloud_off_rounded,
    );
  }
  final all = snapshot.data ?? [];
  final items = app.onlyDownloaded ? all.where(app.isDownloaded).toList() : all;
  if (items.isEmpty) {
    return EmptyState(
      'Здесь пока пусто',
      subtitle: app.onlyDownloaded
          ? 'Загрузите музыку или выключите фильтр «На устройстве».'
          : null,
      icon: Icons.folder_open_rounded,
    );
  }
  final keys = occurrenceKeys(items);
  final rows = List.generate(
    items.length,
    (i) => _LibraryRow(keys[i], items[i], i),
  );
  if (playlistGroups) {
    final server = rows.where((e) => !e.item!.isLocalPlaylist).toList();
    final local = rows.where((e) => e.item!.isLocalPlaylist).toList();
    rows.clear();
    if (server.isNotEmpty) {
      rows.addAll([
        const _LibraryRow('Серверные плейлисты', null, -1),
        ...server,
      ]);
    }
    if (local.isNotEmpty) {
      rows.addAll([
        const _LibraryRow('Локальные плейлисты', null, -1),
        ...local,
      ]);
    }
  }
  return AnimatedRows<_LibraryRow>(
    items: rows,
    idOf: (e) => e.key,
    builder: (context, row, _) => row.item == null
        ? Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
            child: Text(
              row.key,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          )
        : ItemTile(
            item: row.item!,
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
  String? _error;
  Timer? _debounce;
  int _searchRevision = 0;
  AppController get app => widget.app;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      if (widget.scope != null) {
        _all = await app.tracks(widget.scope!);
      } else {
        final unique = <String, LibraryItem>{};
        for (final collection in await app.root(false)) {
          for (final track in await app.tracks(collection)) {
            unique[track.id] = track;
          }
        }
        _all = unique.values.toList()..sort(compareItems);
      }
      if (mounted) {
        setState(() {
          _loading = false;
        });
        unawaited(_filter());
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = AppController.friendly(error);
        });
      }
    }
  }

  Future<void> _filter() async {
    final revision = ++_searchRevision;
    final results = _query.trim().isEmpty
        ? <LibraryItem>[]
        : await findTracks(_all, _query);
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
      SimpleDialog(
        title: const Text('Где продолжить?'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 0),
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Text('В папке этой композиции'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 1),
            child: const Padding(
              padding: EdgeInsets.all(8),
              child: Text('В результатах поиска'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context),
            child: const Text('Отмена'),
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
          name: 'Папка',
          kind: ItemKind.folder,
          path: track.path.substring(
            0,
            track.path.lastIndexOf('/').clamp(0, track.path.length),
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
          decoration: const InputDecoration(
            hintText: 'Файл, исполнитель, композиция',
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
                widget.scope?.name ?? 'Все музыкальные коллекции',
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
                  ? EmptyState(_error!, icon: Icons.cloud_off_rounded)
                  : _results.isEmpty
                  ? EmptyState(
                      _query.isEmpty
                          ? 'Найдите свою музыку'
                          : 'Ничего не найдено',
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
          ListenableBuilder(
            listenable: app,
            builder: (_, _) => MiniPlayer(app: app),
          ),
        ],
      ),
    ),
  );

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}
