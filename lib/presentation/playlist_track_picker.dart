import '../l10n/l10n.dart';
import 'dart:async';
import 'package:flutter/material.dart';

import '../application/app_controller.dart';
import '../application/ports.dart';
import '../domain/library_item.dart';
import '../domain/track_search_index.dart';
import 'widgets.dart';
import 'play_group_action.dart';

class _TrackSelection extends ChangeNotifier {
  final Map<String, LibraryItem> items = {};
  void toggle(LibraryItem track) {
    if (items.remove(track.id) == null) items[track.id] = track;
    notifyListeners();
  }

  void selectAll(Iterable<LibraryItem> tracks) {
    for (final track in tracks.where((e) => e.isTrack)) {
      items[track.id] = track;
    }
    notifyListeners();
  }
}

Future<List<LibraryItem>?> pickPlaylistTracks(
  BuildContext context,
  AppController app,
) async {
  final selection = _TrackSelection();
  final identity = app.libraryIdentity;
  final routes = <TransitionRoute<List<LibraryItem>>>[];
  late TransitionRoute<List<LibraryItem>> root;
  void done(BuildContext current) {
    final result = selection.items.values.toList();
    Navigator.of(current).popUntil((route) => identical(route, root));
    Navigator.of(current).pop(result);
  }

  TransitionRoute<List<LibraryItem>> route(LibraryItem? parent) {
    final result = slideRoute<List<LibraryItem>>(
      _PlaylistTrackPicker(
        app: app,
        parent: parent,
        identity: identity,
        selection: selection,
        onDone: done,
        open: route,
      ),
    );
    routes.add(result);
    return result;
  }

  root = route(null);
  try {
    return await Navigator.push(context, root);
  } finally {
    // Keep the shared selection alive until every outgoing route is disposed.
    unawaited(
      Future.wait(
        routes.map((route) => route.completed),
      ).then((_) => selection.dispose()),
    );
  }
}

class _PlaylistTrackPicker extends StatefulWidget {
  const _PlaylistTrackPicker({
    required this.app,
    required this.parent,
    required this.identity,
    required this.selection,
    required this.onDone,
    required this.open,
  });
  final AppController app;
  final LibraryItem? parent;
  final String identity;
  final _TrackSelection selection;
  final void Function(BuildContext) onDone;
  final Route<List<LibraryItem>> Function(LibraryItem) open;
  @override
  State<_PlaylistTrackPicker> createState() => _PlaylistTrackPickerState();
}

class _PlaylistTrackPickerState extends State<_PlaylistTrackPicker> {
  late Future<List<LibraryItem>> _items = _load();
  Future<List<LibraryItem>>? _searchScope;
  TrackSearchIndex? _searchIndex;
  final _search = TextEditingController();
  List<LibraryItem> _results = [];
  bool _searchOpen = false;
  bool _searching = false;
  Object? _error;
  Timer? _debounce;
  int _revision = 0;
  bool get current => widget.app.libraryIdentity == widget.identity;

  Future<List<LibraryItem>> _load() async {
    final parent = widget.parent;
    final all = parent == null
        ? (await Future.wait([
            widget.app.root(false),
            widget.app.root(true),
          ])).expand((e) => e).toList()
        : await widget.app.children(parent);
    if (!current) throw const AppFailure(AppMessage.theAccountHasChanged);
    // The chooser selects songs; existing draft occurrences remain independent.
    return {for (final item in all) item.id: item}.values.toList();
  }

  Future<List<LibraryItem>> _loadSearchScope() =>
      widget.app.searchTracks(widget.parent);

  void _filter() {
    final revision = ++_revision;
    _debounce?.cancel();
    if (_search.text.trim().isEmpty) {
      setState(() {
        _results = [];
        _error = null;
        _searching = false;
      });
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    _debounce = Timer(const Duration(milliseconds: 220), () async {
      try {
        final all = await (_searchScope ??= _loadSearchScope());
        if (!mounted || !current) return;
        final results = await (_searchIndex ??= TrackSearchIndex(
          all,
        )).find(_search.text.trim());
        if (!mounted || revision != _revision || !current) return;
        setState(() {
          _results = {for (final t in results) t.id: t}.values.toList();
          _searching = false;
        });
      } on Object catch (e) {
        if (!mounted || revision != _revision) return;
        _searchIndex?.dispose();
        _searchIndex = null;
        _searchScope = null;
        setState(() {
          _error = e;
          _searching = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _revision++;
    _searchIndex?.dispose();
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.app, widget.selection]),
    builder: (context, _) => FutureBuilder<List<LibraryItem>>(
      future: _items,
      builder: (context, snapshot) {
        final filtering = _search.text.trim().isNotEmpty;
        final items = filtering ? _results : snapshot.data ?? [];
        final error = filtering ? _error : snapshot.error;
        final loading = filtering
            ? _searching
            : !snapshot.hasData && !snapshot.hasError;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              widget.parent?.displayName ?? context.l10n.addTracks,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                tooltip: context.l10n.selectAllTracks,
                icon: const Icon(Icons.select_all_rounded),
                onPressed: !current || loading || !items.any((t) => t.isTrack)
                    ? null
                    : () => widget.selection.selectAll(items),
              ),
              IconButton(
                tooltip: _searchOpen
                    ? context.l10n.closeSearch
                    : context.l10n.searchTracks,
                icon: Icon(
                  _searchOpen ? Icons.close_rounded : Icons.search_rounded,
                ),
                onPressed: () {
                  FocusScope.of(context).unfocus();
                  setState(() {
                    _searchOpen = !_searchOpen;
                    if (!_searchOpen) _search.clear();
                  });
                  _filter();
                },
              ),
            ],
          ),
          body: Column(
            children: [
              AnimatedSize(
                duration: motionDuration,
                child: !_searchOpen
                    ? const SizedBox.shrink()
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: TextField(
                          controller: _search,
                          autofocus: true,
                          decoration: InputDecoration(
                            hintText: context.l10n.titleArtistOrFileName,
                            prefixIcon: Icon(Icons.search_rounded),
                          ),
                          onChanged: (_) => _filter(),
                        ),
                      ),
              ),
              Expanded(
                child: !current
                    ? EmptyState(
                        context.l10n.theAccountHasChanged,
                        subtitle: context.l10n.closeTheTrackPicker,
                      )
                    : loading
                    ? const Center(child: CircularProgressIndicator())
                    : error != null
                    ? EmptyState(
                        context.l10n.couldNotLoadTracks,
                        subtitle: AppController.friendly(error),
                        action: TextButton(
                          onPressed: () {
                            if (filtering) {
                              _filter();
                            } else {
                              setState(() => _items = _load());
                            }
                          },
                          child: Text(context.l10n.retry),
                        ),
                      )
                    : items.isEmpty
                    ? EmptyState(
                        filtering
                            ? context.l10n.noResults
                            : context.l10n.nothingHereYet,
                      )
                    : AnimatedRows<LibraryItem>(
                        items: items,
                        idOf: (e) => e.id,
                        builder: (context, item, _) => item.isTrack
                            ? CheckboxListTile(
                                value: widget.selection.items.containsKey(
                                  item.id,
                                ),
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                title: Text(
                                  item.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: item.subtitle.isEmpty
                                    ? null
                                    : Text(
                                        item.subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                onChanged: (_) => widget.selection.toggle(item),
                              )
                            : ItemTile(
                                item: item,
                                unavailable: widget.app.isUnavailable(item),
                                onPlay: () => playGroupAndOpenQueue(
                                  context,
                                  widget.app,
                                  item,
                                ),
                                onTap: () =>
                                    Navigator.push(context, widget.open(item)),
                              ),
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: !current || widget.selection.items.isEmpty
                          ? null
                          : () => widget.onDone(context),
                      icon: const Icon(Icons.playlist_add_rounded),
                      label: Text(
                        context.l10n.add(
                          (widget.selection.items.length).toString(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
  );
}
