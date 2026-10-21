import '../l10n/l10n.dart';
import 'dart:async';
import 'package:flutter/material.dart';

import '../application/app_controller.dart';
import '../domain/library_item.dart';
import '../domain/library_search.dart';
import '../infrastructure/download_manager.dart';
import 'actions.dart';
import 'widgets.dart';

/// A device-file view, distinct from the list of requested download groups.
class DownloadedTracksScreen extends StatefulWidget {
  const DownloadedTracksScreen({super.key, required this.app});
  final AppController app;
  @override
  State<DownloadedTracksScreen> createState() => _DownloadedTracksScreenState();
}

class _DownloadedTracksScreenState extends State<DownloadedTracksScreen> {
  late final DownloadManager? _manager;
  List<LibraryItem> _all = const [];
  List<LibraryItem> _visible = const [];
  final _search = TextEditingController();
  Timer? _debounce;
  int _revision = 0;
  bool _searchOpen = false;
  bool _searching = false;
  final Set<String> _removing = {};
  AppController get app => widget.app;
  bool get current => app.loggedIn && identical(app.downloads, _manager);

  @override
  void initState() {
    super.initState();
    _manager = app.downloads;
    app.addListener(_changed);
    _manager?.addListener(_changed);
    _all = _manager?.completedTracks ?? const [];
    _visible = _all;
  }

  void _changed() {
    if (!mounted) return;
    if (!current) {
      _revision++;
      _debounce?.cancel();
      setState(() {});
      return;
    }
    final tracks = _manager!.completedTracks;
    if (identical(tracks, _all)) return;
    _all = tracks;
    _filter(immediate: true);
  }

  void _filter({bool immediate = false}) {
    final revision = ++_revision;
    _debounce?.cancel();
    final query = _search.text.trim();
    if (query.isEmpty) {
      setState(() {
        _visible = _all;
        _searching = false;
      });
      return;
    }
    // Remove stale rows immediately while the new search runs off the UI isolate.
    final ids = _all.map((t) => t.id).toSet();
    setState(() {
      _visible = _visible.where((t) => ids.contains(t.id)).toList();
      _searching = true;
    });
    _debounce = Timer(Duration(milliseconds: immediate ? 0 : 220), () async {
      try {
        final results = await findTracks(_all, query);
        if (!mounted || !current || revision != _revision) return;
        setState(() {
          _visible = results;
          _searching = false;
        });
      } catch (error) {
        if (!mounted || !current || revision != _revision) return;
        setState(() => _searching = false);
        app.message(AppController.friendly(error));
      }
    });
  }

  Future<void> _remove(LibraryItem track) async {
    if (!current || !_removing.add(track.id)) return;
    try {
      final remove = await confirm(
        context,
        context.l10n.removeFromThisDevice((track.title).toString()),
        context.l10n.theDownloadedCopyWillBeRemovedFrom,
      );
      if (remove && mounted && current) {
        await perform(app, () => app.removeDownloadedTrack(track));
        _changed();
      }
    } finally {
      _removing.remove(track.id);
    }
  }

  @override
  void dispose() {
    _revision++;
    _debounce?.cancel();
    app.removeListener(_changed);
    _manager?.removeListener(_changed);
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.l10n.downloadedSongs),
      actions: [
        IconButton(
          tooltip: _searchOpen
              ? context.l10n.closeSearch
              : context.l10n.searchTracks,
          icon: Icon(_searchOpen ? Icons.close_rounded : Icons.search_rounded),
          onPressed: !current
              ? null
              : () {
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
    body: !current
        ? EmptyState(context.l10n.theAccountHasChanged)
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  _search.text.trim().isEmpty
                      ? trackCountLabel(_all.length)
                      : context.l10n.foundOf(
                          (_visible.length).toString(),
                          (_all.length).toString(),
                        ),
                ),
              ),
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
              AnimatedSize(
                duration: motionDuration,
                child: _searching
                    ? const LinearProgressIndicator()
                    : const SizedBox.shrink(),
              ),
              Expanded(
                child: _visible.isEmpty
                    ? EmptyState(
                        _all.isEmpty
                            ? context.l10n.noDownloadedSongsYet
                            : context.l10n.noResults,
                        subtitle: _all.isEmpty
                            ? context.l10n.downloadMusicFromAFolderPlaylistOr
                            : null,
                        icon: Icons.download_outlined,
                      )
                    : AnimatedRows<LibraryItem>(
                        items: _visible,
                        idOf: (track) => track.id,
                        builder: (context, track, _) => ItemGestures(
                          onMenu: () => _remove(track),
                          child: ListTile(
                            minTileHeight: 64,
                            title: Text(
                              track.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              [
                                if (track.subtitle.isNotEmpty) track.subtitle,
                                if (track.durationMs > 0)
                                  timeLabel(
                                    Duration(milliseconds: track.durationMs),
                                  ),
                              ].join(' · '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: IconButton(
                              tooltip: context.l10n.removeFromDevice,
                              icon: const Icon(Icons.delete_outline_rounded),
                              onPressed: () => _remove(track),
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          ),
  );
}
