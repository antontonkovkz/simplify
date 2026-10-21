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
    final current = app.queue.current;
    final colors = Theme.of(context).colorScheme;
    final position = app.queue.currentIndex;
    return AnimatedSize(
      duration: motionDuration,
      curve: Curves.easeOutCubic,
      child: current == null && app.queue.entries.isEmpty
          ? const SizedBox.shrink()
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
                      InkWell(
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
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                          child: AnimatedSwitcher(
                            duration: motionDuration,
                            child: Align(
                              key: ValueKey(current?.id),
                              alignment: Alignment.centerLeft,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    current?.track.title ??
                                        'Очередь · ${app.queue.entries.length}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodyMedium,
                                  ),
                                  Text(
                                    app.waitingForNetwork
                                        ? 'Ожидаем соединения'
                                        : [
                                            if (current
                                                    ?.track
                                                    .subtitle
                                                    .isNotEmpty ==
                                                true)
                                              current!.track.subtitle,
                                            if (position >= 0)
                                              '${position + 1} из ${app.queue.entries.length}',
                                            if (current == null)
                                              'Готово к воспроизведению',
                                          ].join(' · '),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodySmall
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
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _button(
                            tooltip: 'Случайное воспроизведение',
                            selected: app.queue.shuffled,
                            icon: Icons.shuffle_rounded,
                            onPressed: () =>
                                app.setShuffle(!app.queue.shuffled),
                          ),
                          _button(
                            tooltip: 'Предыдущая',
                            icon: Icons.skip_previous_rounded,
                            onPressed: app.queue.canPrevious
                                ? () => perform(app, app.previous)
                                : null,
                          ),
                          _button(
                            tooltip: app.isPlaying ? 'Пауза' : 'Продолжить',
                            icon: app.isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            onPressed: () => perform(
                              app,
                              app.isPlaying || app.waitingForNetwork
                                  ? app.pause
                                  : app.resume,
                            ),
                          ),
                          _button(
                            tooltip: 'Следующая',
                            icon: Icons.skip_next_rounded,
                            onPressed: () =>
                                perform(app, () => app.next(false)),
                          ),
                          if (!inQueue)
                            _button(
                              tooltip: 'Очередь',
                              icon: Icons.queue_music_rounded,
                              onPressed: () => Navigator.push(
                                context,
                                slideRoute(QueueScreen(app: app)),
                              ),
                            )
                          else
                            const SizedBox.square(dimension: 44),
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
          body: const EmptyState('Очередь пуста'),
        );
      }
      final colors = Theme.of(context).colorScheme;
      void menu() => itemMenu(context, app, track);
      return Scaffold(
        appBar: AppBar(
          title: ItemGestures(onMenu: menu, child: const Text('Сейчас играет')),
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
                        queueSourceLabel(app),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        queuePositionLabel(app),
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
                      AnimatedSize(
                        duration: motionDuration,
                        child: app.waitingForNetwork
                            ? Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  app.status ?? 'Ожидаем соединения',
                                  textAlign: TextAlign.center,
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
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
                        label: Text('Очередь · ${app.queue.entries.length}'),
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
          title: const Text('Удалить из очереди'),
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
        SimpleDialog(
          title: const Text('Удалить играющую композицию?'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 0),
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Text('Удалить и включить следующую'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 1),
              child: const Padding(
                padding: EdgeInsets.all(8),
                child: Text('Удалить и дать доиграть'),
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context),
              child: const Text('Отмена'),
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
      final visible = _query.isEmpty
          ? entries
          : entries.where((e) => e.track.matches(_query)).toList();
      return Scaffold(
        appBar: AppBar(
          title: Semantics(
            header: true,
            hint: 'Потяните список вниз или удерживайте заголовок для поиска',
            customSemanticsActions: {
              const CustomSemanticsAction(label: 'Поиск в очереди'): () =>
                  _openSearch(focus: true),
            },
            child: ItemGestures(
              onMenu: () => _openSearch(focus: true),
              child: const Text('Очередь'),
            ),
          ),
          actions: [
            if (_searchOpen)
              IconButton(
                tooltip: 'Закрыть поиск',
                icon: const Icon(Icons.close_rounded),
                onPressed: _closeSearch,
              ),
            PopupMenuButton<String>(
              tooltip: 'Сохранить очередь',
              enabled:
                  !app.serverPlaylist.saving &&
                  (entries.isNotEmpty || app.serverPlaylist.item != null),
              child:
                  MediaQuery.sizeOf(context).width < 360 ||
                      MediaQuery.textScalerOf(context).scale(16) > 21
                  ? SizedBox.square(
                      dimension: 48,
                      child: Center(
                        child: app.serverPlaylist.saving
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
                            if (app.serverPlaylist.saving)
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
                            const Text('Сохранить'),
                          ],
                        ),
                      ),
                    ),
              onSelected: (value) => value == 'server'
                  ? saveServerQueuePlaylist(context, app)
                  : saveQueuePlaylist(context, app, overwrite: value == 'save'),
              itemBuilder: (_) => [
                if (app.loadedLocalPlaylist != null)
                  PopupMenuItem(
                    value: 'save',
                    child: Text(
                      'Сохранить в «${app.loadedLocalPlaylist!.name}»',
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
                        const Text('Сохранить удалённый плейлист'),
                        Text(switch (app.serverPlaylist.access) {
                          PlaylistEditAccess.denied =>
                            'Нет права редактирования',
                          PlaylistEditAccess.checking => 'Проверяем права…',
                          _ =>
                            app.offline
                                ? 'Нет подключения к серверу'
                                : app.serverPlaylist.item!.name,
                        }, style: Theme.of(context).textTheme.bodySmall),
                      ],
                    ),
                  ),
                PopupMenuItem(
                  value: 'as',
                  enabled: entries.isNotEmpty,
                  child: Text(
                    app.serverPlaylist.item == null
                        ? 'Сохранить как…'
                        : 'Как локальный плейлист…',
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
              compact:
                  _searchOpen && MediaQuery.viewInsetsOf(context).bottom > 0,
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
                          hintText: 'Найти в очереди',
                          prefixIcon: const Icon(Icons.search_rounded),
                          suffixIcon: IconButton(
                            tooltip: 'Очистить поиск',
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
                                      ? 'Очередь пуста'
                                      : 'Ничего не найдено',
                                  key: ValueKey(
                                    entries.isEmpty ? 'empty' : 'no-results',
                                  ),
                                  subtitle: entries.isEmpty
                                      ? 'Добавьте композиции из папки или плейлиста.'
                                      : 'Попробуйте другой запрос.',
                                  action: entries.isEmpty
                                      ? null
                                      : TextButton(
                                          onPressed: () {
                                            _search.clear();
                                            setState(() => _query = '');
                                          },
                                          child: const Text('Очистить поиск'),
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
                                              child: const Tooltip(
                                                message: 'Изменить порядок',
                                                child: SizedBox.square(
                                                  dimension: 44,
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
            AnimatedSize(
              duration: motionDuration,
              child: MediaQuery.viewInsetsOf(context).bottom > 0
                  ? const SizedBox.shrink()
                  : MiniPlayer(app: app, inQueue: true),
            ),
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
    final source = queueSourceLabel(app);
    final duration =
        entries.isNotEmpty &&
            entries.every((entry) => entry.track.durationMs > 0)
        ? timeLabel(
            Duration(
              milliseconds: entries.fold<int>(
                0,
                (total, entry) => total + entry.track.durationMs,
              ),
            ),
          )
        : null;
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
                  '$source${app.queueHasChanges ? ' · Изменено' : ''}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            if (!compact) const SizedBox(height: 2),
            Text(
              '${trackCountLabel(entries.length)}${duration == null ? '' : ' · $duration'}',
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
