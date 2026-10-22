import 'dart:async';
import 'package:flutter/material.dart';
import '../application/app_controller.dart';
import '../application/playlist_mutations.dart';
import '../domain/library_item.dart';
import '../l10n/l10n.dart';
import 'widgets.dart';

class PlaylistDeletionScreen extends StatefulWidget {
  const PlaylistDeletionScreen({
    super.key,
    required this.app,
    required this.initial,
  });
  final AppController app;
  final LibraryItem initial;
  @override
  State<PlaylistDeletionScreen> createState() => _PlaylistDeletionScreenState();
}

class _PlaylistDeletionScreenState extends State<PlaylistDeletionScreen> {
  late final String _identity;
  late final PlaylistDeletion _selection;
  List<LibraryItem> _items = [];
  Object? _loadError;
  bool _loading = true;
  String _catalogStamp = '';
  String get _stamp =>
      '${app.libraryIdentity}|${app.catalogRevision}|${app.localRevision}';
  AppController get app => widget.app;
  bool get _current => app.libraryIdentity == _identity;

  @override
  void initState() {
    super.initState();
    _identity = app.libraryIdentity;
    _catalogStamp = _stamp;
    _selection = PlaylistDeletion(
      initial: widget.initial,
      isCurrent: () => _current,
      remove: app.deletePlaylist,
    );
    _selection.addListener(_changed);
    app.addListener(_catalogChanged);
    _merge(app.peekRoot(true) ?? [widget.initial]);
    unawaited(_load());
  }

  void _merge(List<LibraryItem> items) {
    _items =
        {
          for (final item in [...items, ..._selection.selected.values])
            if (item.isPlaylist && !_selection.deleted.contains(item.id))
              item.id: item,
        }.values.toList()..sort((a, b) {
          if (a.isLocalPlaylist != b.isLocalPlaylist) {
            return a.isLocalPlaylist ? 1 : -1;
          }
          return compareItems(a, b);
        });
  }

  Future<void> _load() async {
    try {
      final items = await app.root(true);
      if (!mounted || !_current) return;
      setState(() {
        _merge(items);
        _loadError = null;
      });
    } catch (error) {
      if (mounted) setState(() => _loadError = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _catalogChanged() {
    if (!mounted || _catalogStamp == _stamp) return;
    _catalogStamp = _stamp;
    final snapshot = app.peekRoot(true);
    setState(() {
      if (snapshot != null && _current) _merge(snapshot);
    });
  }

  void _changed() {
    if (mounted) {
      setState(() {
        if (_items.any((item) => _selection.deleted.contains(item.id))) {
          _items = _items
              .where((item) => !_selection.deleted.contains(item.id))
              .toList();
        }
      });
    }
  }

  Future<void> _delete() async {
    final chosen = _selection.selected.values.toList();
    if (chosen.isEmpty || !_current) return;
    final confirmed = await appDialog<bool>(
      context,
      AlertDialog(
        scrollable: true,
        title: Text(
          context.l10n.confirmDeletePlaylists(chosen.length.toString()),
        ),
        content: Text(
          '${chosen.map((item) => item.displayName).join('\n')}\n\n${context.l10n.deletePlaylistsExplanation}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.deleteAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !_current) return;
    await _selection.deleteSelected();
    if (!mounted || !_current) return;
    if (_selection.errors.isEmpty && _selection.selected.isEmpty) {
      app.message(AppMessage.playlistsDeleted(chosen.length));
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    app.removeListener(_catalogChanged);
    _selection.removeListener(_changed);
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_selection.deleting,
    child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: IconButton(
          tooltip: context.l10n.cancel,
          icon: const Icon(Icons.close_rounded),
          onPressed: _selection.deleting ? null : () => Navigator.pop(context),
        ),
        title: Text(
          context.l10n.selectedPlaylists(_selection.selected.length.toString()),
        ),
        actions: [
          IconButton(
            tooltip: context.l10n.deleteSelectedPlaylists,
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed:
                !_current || _selection.deleting || _selection.selected.isEmpty
                ? null
                : _delete,
          ),
        ],
      ),
      body: !_current
          ? EmptyState(context.l10n.theAccountHasChanged)
          : Column(
              children: [
                if (_selection.deleting) ...[
                  LinearProgressIndicator(
                    value: _selection.total == 0
                        ? null
                        : _selection.completed / _selection.total,
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      context.l10n.deletingPlaylists(
                        _selection.completed.toString(),
                        _selection.total.toString(),
                      ),
                    ),
                  ),
                ] else if (_loading)
                  const LinearProgressIndicator(),
                if (_loadError != null)
                  ListTile(
                    title: Text(AppController.friendly(_loadError!)),
                    trailing: IconButton(
                      tooltip: context.l10n.retry,
                      icon: const Icon(Icons.refresh_rounded),
                      onPressed: () {
                        setState(() {
                          _loading = true;
                          _loadError = null;
                        });
                        unawaited(_load());
                      },
                    ),
                  ),
                Expanded(
                  child: AnimatedRows<LibraryItem>(
                    items: _items,
                    idOf: (item) => item.id,
                    builder: (context, item, index) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (index >= 0 &&
                            index < _items.length &&
                            (index == 0 ||
                                _items[index - 1].isLocalPlaylist !=
                                    item.isLocalPlaylist))
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                            child: Text(
                              item.isLocalPlaylist
                                  ? context.l10n.localPlaylists
                                  : context.l10n.serverPlaylists,
                            ),
                          ),
                        CheckboxListTile(
                          key: ValueKey('delete-playlist:${item.id}'),
                          value: _selection.selected.containsKey(item.id),
                          onChanged: _selection.deleting
                              ? null
                              : (_) => _selection.toggle(item),
                          title: Text(item.displayName),
                          subtitle: _selection.errors[item.id] != null
                              ? Text(
                                  AppController.friendly(
                                    _selection.errors[item.id]!,
                                  ),
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                )
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    ),
  );
}
