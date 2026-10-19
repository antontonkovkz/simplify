import 'dart:async';
import 'package:flutter/material.dart' hide RepeatMode;
import '../application/app_controller.dart';
import '../application/server_playlist_editor.dart';
import '../domain/queue_engine.dart';
import 'actions.dart';
import 'widgets.dart';
import 'queue_row.dart';

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
    final position = app.queue.entries.indexWhere(
      (entry) => entry.id == current?.id,
    );
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
  double? _seeking;
  AppController get app => widget.app;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      final track = app.queue.current?.track;
      if (track == null) {
        return Scaffold(
          appBar: AppBar(),
          body: const EmptyState('Очередь пуста'),
        );
      }
      final colors = Theme.of(context).colorScheme;
      return Scaffold(
        appBar: AppBar(
          title: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPress: () => itemMenu(context, app, track),
            child: const Text('Сейчас играет'),
          ),
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 20,
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      GestureDetector(
                        onLongPress: () => itemMenu(context, app, track),
                        child: AnimatedSwitcher(
                          duration: motionDuration,
                          child: Container(
                            key: ValueKey(track.id),
                            width: 250,
                            height: 250,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(36),
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [
                                  colors.primary.withValues(alpha: .32),
                                  colors.surfaceContainerHighest,
                                ],
                              ),
                            ),
                            child: Icon(
                              Icons.music_note_rounded,
                              size: 100,
                              color: colors.primary,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 32),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onLongPress: () => itemMenu(context, app, track),
                        child: AnimatedSwitcher(
                          duration: motionDuration,
                          child: Column(
                            key: ValueKey(track.id),
                            children: [
                              Text(
                                track.title,
                                textAlign: TextAlign.center,
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall,
                              ),
                              if (track.subtitle.isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  track.subtitle,
                                  textAlign: TextAlign.center,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      StreamBuilder<Duration>(
                        stream: app.audio.player.positionStream,
                        initialData: app.audio.player.position,
                        builder: (context, snapshot) {
                          final duration =
                              (app.hasLoadedCurrent
                                  ? app.audio.player.duration
                                  : null) ??
                              Duration(milliseconds: track.durationMs);
                          final max = duration.inMilliseconds
                              .toDouble()
                              .clamp(1.0, double.infinity)
                              .toDouble();
                          final position =
                              (_seeking ??
                                      (app.hasLoadedCurrent
                                              ? snapshot.data ?? Duration.zero
                                              : app.position)
                                          .inMilliseconds
                                          .toDouble())
                                  .clamp(0.0, max)
                                  .toDouble();
                          return Column(
                            children: [
                              Slider(
                                value: position,
                                max: max,
                                onChangeStart: (v) => setState(() {
                                  _seeking = v;
                                }),
                                onChanged: (v) => setState(() {
                                  _seeking = v;
                                }),
                                onChangeEnd: (v) {
                                  unawaited(
                                    app.audio.seek(
                                      Duration(milliseconds: v.round()),
                                    ),
                                  );
                                  setState(() {
                                    _seeking = null;
                                  });
                                },
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      timeLabel(
                                        Duration(
                                          milliseconds: position.round(),
                                        ),
                                      ),
                                    ),
                                    Text(timeLabel(duration)),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                      AnimatedSwitcher(
                        duration: motionDuration,
                        child: app.waitingForNetwork
                            ? Padding(
                                key: const ValueKey('waiting'),
                                padding: const EdgeInsets.only(top: 16),
                                child: Text(app.status ?? 'Ожидаем соединения'),
                              )
                            : const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            tooltip: 'Случайное воспроизведение',
                            isSelected: app.queue.shuffled,
                            onPressed: () =>
                                app.setShuffle(!app.queue.shuffled),
                            icon: const Icon(Icons.shuffle_rounded),
                          ),
                          IconButton(
                            tooltip: 'Предыдущая',
                            iconSize: 36,
                            onPressed: app.queue.canPrevious
                                ? () => perform(app, app.previous)
                                : null,
                            icon: const Icon(Icons.skip_previous_rounded),
                          ),
                          SizedBox(
                            width: 72,
                            height: 72,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                padding: EdgeInsets.zero,
                                shape: const CircleBorder(),
                              ),
                              onPressed: () => perform(
                                app,
                                app.isPlaying || app.waitingForNetwork
                                    ? app.pause
                                    : app.resume,
                              ),
                              child: Icon(
                                app.isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                size: 42,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Следующая',
                            iconSize: 36,
                            onPressed: () =>
                                perform(app, () => app.next(false)),
                            icon: const Icon(Icons.skip_next_rounded),
                          ),
                          IconButton(
                            tooltip: switch (app.queue.repeat) {
                              RepeatMode.off => 'Повтор выключен',
                              RepeatMode.all => 'Повтор очереди',
                              RepeatMode.one => 'Повтор композиции',
                            },
                            isSelected: app.queue.repeat != RepeatMode.off,
                            onPressed: () => app.setRepeat(
                              RepeatMode.values[(app.queue.repeat.index + 1) %
                                  3],
                            ),
                            icon: Icon(
                              app.queue.repeat == RepeatMode.one
                                  ? Icons.repeat_one_rounded
                                  : Icons.repeat_rounded,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 32),
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
              ),
            ),
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
  }

  final _search = TextEditingController();
  bool _searchOpen = false;
  String _query = '';
  AppController get app => widget.app;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toggleSearch() {
    FocusScope.of(context).unfocus();
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _search.clear();
        _query = '';
      }
    });
  }

  Future<void> _entryMenu(QueueEntry entry) async {
    final remove = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: ListTile(
          leading: const Icon(Icons.delete_outline_rounded),
          title: const Text('Удалить из очереди'),
          onTap: () => Navigator.pop(context, true),
        ),
      ),
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
          title: const Text('Очередь'),
          actions: [
            IconButton(
              tooltip: _searchOpen ? 'Закрыть поиск' : 'Поиск в очереди',
              icon: Icon(
                _searchOpen ? Icons.search_off_rounded : Icons.search_rounded,
              ),
              onPressed: _toggleSearch,
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
                        autofocus: true,
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
            Expanded(
              child: AnimatedSwitcher(
                duration: motionDuration,
                child: visible.isEmpty
                    ? EmptyState(
                        entries.isEmpty ? 'Очередь пуста' : 'Ничего не найдено',
                        key: ValueKey(entries.isEmpty ? 'empty' : 'no-results'),
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
                        idOf: (e) => e.id,
                        onReorder: _query.isEmpty ? app.move : null,
                        builder: (context, entry, index) {
                          final original = entries.indexWhere(
                            (item) => item.id == entry.id,
                          );
                          return QueueRow(
                            entry: entry,
                            position: original < 0 ? null : original + 1,
                            active: entry.id == app.queue.current?.id,
                            downloaded: app.isDownloaded(entry.track),
                            onTap: () =>
                                perform(app, () => app.selectIndex(original)),
                            onMenu: () => _entryMenu(entry),
                            onRemove: () => _remove(entry),
                            onMoveUp: _query.isEmpty && original > 0
                                ? () => app.move(original, original - 1)
                                : null,
                            onMoveDown:
                                _query.isEmpty &&
                                    original >= 0 &&
                                    original < entries.length - 1
                                ? () => app.move(original, original + 2)
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
    final local = app.loadedLocalPlaylist;
    final server = app.serverPlaylist.item;
    final source = local != null
        ? 'Локальный плейлист «${local.name}»'
        : server != null
        ? 'Из «${server.name}»'
        : 'Текущая очередь';
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
