import 'dart:async';
import 'package:flutter/material.dart' hide RepeatMode;
import '../application/app_controller.dart';
import '../application/server_playlist_editor.dart';
import '../domain/queue_engine.dart';
import 'actions.dart';
import 'widgets.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.app, this.inQueue = false});
  final AppController app;
  final bool inQueue;
  @override
  Widget build(BuildContext context) {
    final current = app.queue.current;
    return AnimatedSize(
      duration: motionDuration,
      child: current == null && app.queue.entries.isEmpty
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(20),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: current == null && inQueue
                      ? null
                      : () => Navigator.push(
                          context,
                          slideRoute(
                            current == null
                                ? QueueScreen(app: app)
                                : PlayerScreen(app: app, queueBelow: inQueue),
                          ),
                        ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.graphic_eq_rounded,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
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
                                            'Очередь · ${app.queue.entries.length}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      Text(
                                        app.waitingForNetwork
                                            ? 'Ожидаем соединения'
                                            : current?.track.subtitle ??
                                                  'Готово к воспроизведению',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            if (!inQueue)
                              IconButton(
                                tooltip: 'Очередь',
                                icon: const Icon(Icons.queue_music_rounded),
                                onPressed: () => Navigator.push(
                                  context,
                                  slideRoute(QueueScreen(app: app)),
                                ),
                              ),
                          ],
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  onPressed: () =>
                                      app.setShuffle(!app.queue.shuffled),
                                  icon: Icon(
                                    app.queue.shuffled
                                        ? Icons.shuffle_rounded
                                        : Icons.playlist_play_rounded,
                                    size: 18,
                                  ),
                                  label: Text(
                                    app.queue.shuffled
                                        ? 'Случайно'
                                        : 'По порядку',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    textStyle: const TextStyle(fontSize: 12),
                                    foregroundColor: app.queue.shuffled
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(
                                            context,
                                          ).colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Предыдущая',
                              icon: const Icon(Icons.skip_previous_rounded),
                              onPressed: app.queue.canPrevious
                                  ? () => perform(app, app.previous)
                                  : null,
                            ),
                            IconButton(
                              tooltip: app.isPlaying ? 'Пауза' : 'Продолжить',
                              icon: Icon(
                                app.isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                              onPressed: () => perform(
                                app,
                                app.isPlaying || app.waitingForNetwork
                                    ? app.pause
                                    : app.resume,
                              ),
                            ),
                            IconButton(
                              tooltip: 'Следующая',
                              icon: const Icon(Icons.skip_next_rounded),
                              onPressed: () =>
                                  perform(app, () => app.next(false)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
    );
  }
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

  String _query = '';
  AppController get app => widget.app;
  Future<void> _remove(QueueEntry entry) async {
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
      if (choice == null) return;
      finish = choice == 1;
    }
    await perform(app, () => app.remove(entry.id, finish: finish));
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
          title: Text('Очередь · ${entries.length}'),
          actions: [
            PopupMenuButton<String>(
              tooltip: 'Сохранить очередь',
              enabled:
                  !app.serverPlaylist.saving &&
                  (entries.isNotEmpty || app.serverPlaylist.item != null),
              icon: AnimatedSwitcher(
                duration: motionDuration,
                child: app.serverPlaylist.saving
                    ? const SizedBox(
                        key: ValueKey('saving'),
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined, key: ValueKey('save')),
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
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(58),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Найти в очереди',
                  prefixIcon: Icon(Icons.search_rounded),
                ),
                onChanged: (v) => setState(() {
                  _query = v;
                }),
              ),
            ),
          ),
        ),
        body: Column(
          children: [
            Expanded(
              child: visible.isEmpty
                  ? const EmptyState('Очередь пуста')
                  : AnimatedRows<QueueEntry>(
                      items: visible,
                      idOf: (e) => e.id,
                      onReorder: _query.isEmpty ? app.move : null,
                      builder: (context, entry, index) => ItemTile(
                        item: entry.track,
                        active: entry.id == app.queue.current?.id,
                        downloaded: app.isDownloaded(entry.track),
                        onTap: () => perform(
                          app,
                          () => app.selectIndex(
                            entries.indexWhere((e) => e.id == entry.id),
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Удалить из очереди',
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () => _remove(entry),
                            ),
                            if (_query.isEmpty && index >= 0)
                              ReorderableDragStartListener(
                                index: index,
                                child: const Padding(
                                  padding: EdgeInsets.all(12),
                                  child: Icon(Icons.drag_handle_rounded),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
            ),
            MiniPlayer(app: app, inQueue: true),
          ],
        ),
      );
    },
  );
}
