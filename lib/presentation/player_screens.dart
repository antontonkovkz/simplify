import 'shuffle_button.dart';
import 'playback_activity.dart';
import '../l10n/l10n.dart';
import 'dart:async';
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:flutter/semantics.dart';
import '../application/app_controller.dart';
import '../application/server_playlist_editor.dart';
import '../domain/queue_engine.dart';
import 'actions.dart';
import 'widgets.dart';
import 'queue_row.dart';
import 'queue_context.dart';
import 'playback_timeline.dart';
import 'player_controls.dart';
import 'action_sheet.dart';
import 'queue_preparation_status.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({
    super.key,
    required this.app,
    this.inQueue = false,
    this.bottomSafeArea = true,
  });
  final AppController app;
  final bool inQueue;
  final bool bottomSafeArea;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => _buildPlayer(context),
    );
  }

  Widget _buildPlayer(BuildContext context) {
    final current = app.queue.current;
    final colors = Theme.of(context).colorScheme;
    final position = app.queue.currentIndex;
    return AnimatedSize(
      duration: motionDuration,
      curve: Curves.easeOutCubic,
      child: current == null && app.queue.entries.isEmpty
          ? const SizedBox.shrink()
          : app.miniPlayerCollapsed
          ? SafeArea(
              top: false,
              bottom: bottomSafeArea,
              child: Align(
                alignment: Alignment.centerRight,
                heightFactor: 1,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextButton.icon(
                    key: const ValueKey('show-mini-player'),
                    onPressed: () => app.setMiniPlayerCollapsed(false),
                    icon: const Icon(Icons.expand_less_rounded),
                    label: Text(context.l10n.showMiniPlayer),
                  ),
                ),
              ),
            )
          : SafeArea(
              top: false,
              bottom: bottomSafeArea,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
                child: Material(
                  key: const ValueKey('mini-player-surface'),
                  color: colors.surfaceContainerHigh,
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              onTap: current == null && inQueue
                                  ? null
                                  : () => Navigator.push(
                                      context,
                                      slideRoute(
                                        current == null
                                            ? QueueScreen(app: app)
                                            : PlayerScreen(
                                                app: app,
                                                queueBelow: inQueue,
                                              ),
                                      ),
                                    ),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  8,
                                  12,
                                  0,
                                ),
                                child: AnimatedSwitcher(
                                  duration: motionDuration,
                                  child: Align(
                                    key: ValueKey(current?.id),
                                    alignment: Alignment.centerLeft,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          current?.track.title ??
                                              context.l10n.queue2(
                                                (app.queue.entries.length)
                                                    .toString(),
                                              ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodyMedium,
                                        ),
                                        Text(
                                          app.waitingForNetwork
                                              ? context
                                                    .l10n
                                                    .waitingForAConnection
                                              : [
                                                  if (current
                                                          ?.track
                                                          .subtitle
                                                          .isNotEmpty ==
                                                      true)
                                                    current!.track.subtitle,
                                                  if (position >= 0)
                                                    context.l10n.of2(
                                                      (position + 1).toString(),
                                                      (app.queue.entries.length)
                                                          .toString(),
                                                    ),
                                                  if (current == null)
                                                    context.l10n.readyToPlay,
                                                ].join(' · '),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: colors.onSurfaceVariant,
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: context.l10n.hideMiniPlayer,
                            onPressed: () => app.setMiniPlayerCollapsed(true),
                            icon: const Icon(Icons.expand_more_rounded),
                          ),
                        ],
                      ),
                      if (current != null)
                        PlaybackTimeline(
                          key: ValueKey('mini-timeline-${current.id}'),
                          app: app,
                          compact: true,
                        ),
                      PlaybackActivity(app: app),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          ShuffleButton(app: app),
                          _button(
                            tooltip: context.l10n.previous,
                            icon: Icons.skip_previous_rounded,
                            onPressed: app.queue.canPrevious
                                ? () => perform(app, app.previous)
                                : null,
                          ),
                          _button(
                            tooltip:
                                app.isPlaying ||
                                    app.waitingForNetwork ||
                                    app.wantsPlayback
                                ? context.l10n.pause
                                : context.l10n.continueAction,
                            icon:
                                app.isPlaying ||
                                    app.waitingForNetwork ||
                                    app.wantsPlayback
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            onPressed: () => perform(
                              app,
                              app.isPlaying ||
                                      app.waitingForNetwork ||
                                      app.wantsPlayback
                                  ? app.pause
                                  : app.resume,
                            ),
                          ),
                          _button(
                            tooltip: context.l10n.next,
                            icon: Icons.skip_next_rounded,
                            onPressed: () =>
                                perform(app, () => app.next(false)),
                          ),
                          if (!inQueue)
                            _button(
                              tooltip: context.l10n.queue,
                              icon: Icons.queue_music_rounded,
                              onPressed: () => Navigator.push(
                                context,
                                slideRoute(QueueScreen(app: app)),
                              ),
                            )
                          else
                            const SizedBox.square(dimension: 48),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _button({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool? selected,
  }) => IconButton(
    tooltip: tooltip,
    isSelected: selected,
    constraints: const BoxConstraints.tightFor(width: 44, height: 44),
    padding: const EdgeInsets.all(10),
    icon: Icon(icon),
    onPressed: onPressed,
  );
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.app, this.queueBelow = false});
  final AppController app;
  final bool queueBelow;
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  AppController get app => widget.app;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final entry = app.queue.current;
      final track = entry?.track;
      if (track == null) {
        return Scaffold(
          appBar: AppBar(),
          body: EmptyState(context.l10n.theQueueIsEmpty),
        );
      }
      final colors = Theme.of(context).colorScheme;
      void menu() => itemMenu(context, app, track);
      return Scaffold(
        appBar: AppBar(
          title: ItemGestures(
            onMenu: menu,
            child: Text(context.l10n.nowPlaying),
          ),
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
              final artwork = (constraints.maxHeight * .22 / textScale).clamp(
                64.0,
                160.0,
              );
              return SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight - 24).clamp(
                      0,
                      double.infinity,
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        queueSourceLabel(context, app),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        queuePositionLabel(context, app),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ItemGestures(
                        onMenu: menu,
                        child: AnimatedContainer(
                          key: const ValueKey('player-artwork'),
                          duration: motionDuration,
                          width: artwork,
                          height: artwork,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(24),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                colors.primary.withValues(alpha: .24),
                                colors.surfaceContainerHighest,
                              ],
                            ),
                          ),
                          child: Icon(
                            Icons.music_note_rounded,
                            size: artwork * .4,
                            color: colors.primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      ItemGestures(
                        onMenu: menu,
                        child: AnimatedSwitcher(
                          duration: motionDuration,
                          child: Column(
                            key: ValueKey(entry!.id),
                            children: [
                              Text(
                                track.title,
                                textAlign: TextAlign.center,
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall,
                              ),
                              if (track.subtitle.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                Text(
                                  track.subtitle,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.titleMedium
                                      ?.copyWith(
                                        color: colors.onSurfaceVariant,
                                      ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      PlaybackTimeline(
                        key: ValueKey('timeline-${entry.id}'),
                        app: app,
                      ),
                      PlaybackActivity(app: app),
                      const SizedBox(height: 20),
                      PlayerControls(app: app),
                      const SizedBox(height: 20),
                      OutlinedButton.icon(
                        onPressed: () {
                          if (widget.queueBelow) {
                            Navigator.pop(context);
                          } else {
                            Navigator.push(
                              context,
                              slideRoute(QueueScreen(app: app)),
                            );
                          }
                        },
                        icon: const Icon(Icons.queue_music_rounded),
                        label: Text(
                          context.l10n.queue2(
                            (app.queue.entries.length).toString(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
    },
  );
}

class QueueScreen extends StatefulWidget {
  const QueueScreen({super.key, required this.app});
  final AppController app;
  @override
  State<QueueScreen> createState() => _QueueScreenState();
}

class _QueueScreenState extends State<QueueScreen> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.app.serverPlaylist.refreshAccess(widget.app.library));
    _seenCurrent = widget.app.queue.current?.id;
    widget.app.addListener(_playbackChanged);
  }

  String? _seenCurrent;
  void _playbackChanged() {
    final current = app.queue.current;
    if (current?.id == _seenCurrent) return;
    _seenCurrent = current?.id;
    if (_query.isNotEmpty &&
        current != null &&
        !current.track.matches(_query)) {
      _search.clear();
      setState(() => _query = '');
    }
  }

  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  double _pullDistance = 0;
  bool _searchOpen = false;
  String _query = '';
  List<QueueEntry>? _filterSource;
  String? _filterQuery;
  List<QueueEntry> _filtered = const [];

  List<QueueEntry> _visibleEntries(List<QueueEntry> entries) {
    final needle = _query.trim().toLowerCase();
    if (needle.isEmpty) return entries;
    if (!identical(entries, _filterSource) || needle != _filterQuery) {
      _filterSource = entries;
      _filterQuery = needle;
      _filtered = entries
          .where((entry) => entry.track.matchesNeedle(needle))
          .toList(growable: false);
    }
    return _filtered;
  }

  AppController get app => widget.app;

  @override
  void dispose() {
    app.removeListener(_playbackChanged);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _openSearch({bool focus = false}) {
    if (!_searchOpen) setState(() => _searchOpen = true);
    if (focus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    }
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    setState(() {
      _searchOpen = false;
      _search.clear();
      _query = '';
    });
  }

  bool _handleSearchPull(ScrollNotification notification) {
    if (_searchOpen ||
        notification.depth != 0 ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification is ScrollStartNotification) _pullDistance = 0;
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      final overscroll =
          notification.metrics.minScrollExtent - notification.metrics.pixels;
      if (overscroll > 48) _openSearch();
    }
    if (notification is OverscrollNotification &&
        notification.dragDetails != null) {
      _pullDistance = (_pullDistance - notification.overscroll).clamp(0, 100);
      if (_pullDistance > 48) _openSearch();
    }
    return false;
  }

  Future<void> _entryMenu(QueueEntry entry) async {
    final remove = await showActionSheet<bool>(
      context: context,
      title: entry.track.title,
      actions: (sheet) => [
        ListTile(
          leading: const Icon(Icons.delete_outline_rounded),
          title: Text(context.l10n.removeFromQueue),
          onTap: () => Navigator.pop(sheet, true),
        ),
      ],
    );
    if (remove == true && mounted) await _remove(entry);
  }

  Future<bool> _remove(QueueEntry entry) async {
    var finish = false;
    if (entry.id == app.queue.current?.id) {
      final choice = await appDialog<int>(
        context,
        (context) => SimpleDialog(
          title: Text(context.l10n.removeThePlayingTrack),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 0),
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Text(context.l10n.removeAndPlayNext),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 1),
              child: Padding(
                padding: EdgeInsets.all(8),
                child: Text(context.l10n.removeAndFinishPlaying),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.cancel),
            ),
          ],
        ),
      );
      if (choice == null || !mounted) return false;
      finish = choice == 1;
    }
    await perform(app, () => app.remove(entry.id, finish: finish));
    return !app.queue.entries.any((item) => item.id == entry.id);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final entries = app.queue.entries;
      final visible = _visibleEntries(entries);
      return Scaffold(
        appBar: AppBar(
          title: Semantics(
            header: true,
            hint: context.l10n.pullDownTheListOrHoldThe,
            customSemanticsActions: {
              CustomSemanticsAction(label: context.l10n.searchInQueue): () =>
                  _openSearch(focus: true),
            },
            child: ItemGestures(
              onMenu: () => _openSearch(focus: true),
              child: Text(context.l10n.queue),
            ),
          ),
          actions: [
            if (_searchOpen)
              IconButton(
                tooltip: context.l10n.closeSearch,
                icon: const Icon(Icons.close_rounded),
                onPressed: _closeSearch,
              ),
            PopupMenuButton<String>(
              tooltip: context.l10n.saveQueue,
              enabled:
                  !app.serverPlaylist.saving &&
                  !app.creatingServerPlaylist &&
                  (entries.isNotEmpty || app.serverPlaylist.item != null),
              child:
                  MediaQuery.sizeOf(context).width < 360 ||
                      MediaQuery.textScalerOf(context).scale(16) > 21
                  ? SizedBox.square(
                      dimension: 48,
                      child: Center(
                        child:
                            (app.serverPlaylist.saving ||
                                app.creatingServerPlaylist)
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.save_outlined),
                      ),
                    )
                  : ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (app.serverPlaylist.saving ||
                                app.creatingServerPlaylist)
                              const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            else
                              const Icon(Icons.save_outlined, size: 18),
                            const SizedBox(width: 6),
                            Text(context.l10n.save),
                          ],
                        ),
                      ),
                    ),
              onSelected: (value) => value == 'newServer'
                  ? createServerQueuePlaylist(context, app)
                  : value == 'server'
                  ? saveServerQueuePlaylist(context, app)
                  : saveQueuePlaylist(context, app, overwrite: value == 'save'),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'newServer',
                  enabled:
                      app.loggedIn &&
                      !app.offline &&
                      entries.isNotEmpty &&
                      app.queue.allServerTracks,
                  child: Text(context.l10n.saveAsNewServerPlaylist),
                ),
                if (app.loadedLocalPlaylist != null)
                  PopupMenuItem(
                    value: 'save',
                    child: Text(
                      context.l10n.saveTo(
                        (app.loadedLocalPlaylist!.displayName).toString(),
                      ),
                    ),
                  ),
                if (app.serverPlaylist.item != null)
                  PopupMenuItem(
                    value: 'server',
                    enabled:
                        !app.offline &&
                        app.serverPlaylist.access !=
                            PlaylistEditAccess.denied &&
                        app.serverPlaylist.access !=
                            PlaylistEditAccess.checking,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(context.l10n.saveServerPlaylist),
                        Text(switch (app.serverPlaylist.access) {
                          PlaylistEditAccess.denied =>
                            context.l10n.noEditingPermission,
                          PlaylistEditAccess.checking =>
                            context.l10n.checkingPermissions,
                          _ =>
                            app.offline
                                ? context.l10n.noServerConnection
                                : app.serverPlaylist.item!.displayName,
                        }, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                PopupMenuItem(
                  value: 'as',
                  enabled: entries.isNotEmpty,
                  child: Text(
                    app.serverPlaylist.item == null
                        ? context.l10n.saveAs
                        : context.l10n.asALocalPlaylist,
                  ),
                ),
              ],
            ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _QueueSummary(
              app: app,
              compact: MediaQuery.viewInsetsOf(context).bottom > 0,
            ),
            AnimatedSize(
              duration: motionDuration,
              curve: Curves.easeOutCubic,
              child: !_searchOpen
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: TextField(
                        controller: _search,
                        focusNode: _searchFocus,
                        decoration: InputDecoration(
                          hintText: context.l10n.searchQueue,
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: IconButton(
                            tooltip: context.l10n.clearSearch,
                            icon: const Icon(Icons.close_rounded),
                            onPressed: () {
                              _search.clear();
                              setState(() => _query = '');
                            },
                          ),
                        ),
                        onChanged: (value) =>
                            setState(() => _query = value.trim()),
                      ),
                    ),
            ),
            QueuePreparationStatus(app: app),
            Expanded(
              child: app.resolvingGroup
                  ? const Center(child: CircularProgressIndicator())
                  : NotificationListener<ScrollNotification>(
                      onNotification: _handleSearchPull,
                      child: ScrollConfiguration(
                        behavior: ScrollConfiguration.of(context).copyWith(
                          physics: const AlwaysScrollableScrollPhysics(
                            parent: BouncingScrollPhysics(),
                          ),
                        ),
                        child: AnimatedSwitcher(
                          duration: motionDuration,
                          child: visible.isEmpty
                              ? EmptyState(
                                  entries.isEmpty
                                      ? context.l10n.theQueueIsEmpty
                                      : context.l10n.noResults,
                                  key: ValueKey(
                                    entries.isEmpty ? 'empty' : 'no-results',
                                  ),
                                  subtitle: entries.isEmpty
                                      ? context
                                            .l10n
                                            .addTracksFromAFolderOrPlaylist
                                      : context.l10n.tryADifferentSearch,
                                  action: entries.isEmpty
                                      ? null
                                      : TextButton(
                                          onPressed: () {
                                            _search.clear();
                                            setState(() => _query = '');
                                          },
                                          child: Text(context.l10n.clearSearch),
                                        ),
                                )
                              : AnimatedRows<QueueEntry>(
                                  key: const ValueKey('queue-entries'),
                                  items: visible,
                                  indexed: true,
                                  followId: app.queue.viewAnchorId,
                                  followScope: _query,
                                  animateFollow:
                                      ModalRoute.of(context)?.isCurrent !=
                                      false,
                                  idOf: (e) => e.id,
                                  onReorder: _query.isEmpty ? app.move : null,
                                  builder: (context, entry, index) {
                                    final original = app.queue.indexOfEntry(
                                      entry.id,
                                    );
                                    return QueueRow(
                                      entry: entry,
                                      unavailable: app.isUnavailable(
                                        entry.track,
                                      ),
                                      position: original < 0
                                          ? null
                                          : original + 1,
                                      active: entry.id == app.queue.current?.id,
                                      downloaded: app.isDownloaded(entry.track),
                                      onTap: () => perform(
                                        app,
                                        () => app.selectIndex(original),
                                      ),
                                      onMenu: () => _entryMenu(entry),
                                      onRemove: () => _remove(entry),
                                      onMoveUp: _query.isEmpty && original > 0
                                          ? () =>
                                                app.move(original, original - 1)
                                          : null,
                                      onMoveDown:
                                          _query.isEmpty &&
                                              original >= 0 &&
                                              original < entries.length - 1
                                          ? () =>
                                                app.move(original, original + 2)
                                          : null,
                                      dragHandle: _query.isEmpty && index >= 0
                                          ? ReorderableDragStartListener(
                                              index: index,
                                              child: Tooltip(
                                                message: context.l10n.reorder,
                                                child: SizedBox.square(
                                                  dimension: 48,
                                                  child: Icon(
                                                    Icons.drag_handle_rounded,
                                                    size: 22,
                                                  ),
                                                ),
                                              ),
                                            )
                                          : null,
                                    );
                                  },
                                ),
                        ),
                      ),
                    ),
            ),
            // The keyboard animates the viewport. Release the player height
            // immediately so its old size cannot overflow during that resize.
            if (MediaQuery.viewInsetsOf(context).bottom == 0)
              MiniPlayer(app: app, inQueue: true),
          ],
        ),
      );
    },
  );
}

class _QueueSummary extends StatelessWidget {
  const _QueueSummary({required this.app, this.compact = false});
  final AppController app;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final entries = app.queue.entries;
    final source = queueSourceLabel(context, app);
    final totalDuration = app.queue.totalDuration;
    final duration = totalDuration == null ? null : timeLabel(totalDuration);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: AnimatedSize(
        duration: motionDuration,
        alignment: Alignment.topLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!compact)
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '$source${app.queueHasChanges ? context.l10n.modified : ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            if (!compact) const SizedBox(height: 2),
            Text(
              '${trackCountLabel(context, entries.length)}${duration == null ? '' : ' · $duration'}',
              maxLines: compact ? 1 : null,
              overflow: compact ? TextOverflow.ellipsis : null,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
