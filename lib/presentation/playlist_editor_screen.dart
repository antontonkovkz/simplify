import 'dart:async';
import 'package:flutter/material.dart';

import '../application/app_controller.dart';
import '../application/playlist_edit_session.dart';
import '../application/server_playlist_editor.dart';
import '../domain/library_item.dart';
import '../domain/playlist_draft.dart';
import 'action_sheet.dart';
import 'actions.dart';
import 'editable_track_row.dart';
import 'player_screens.dart';
import 'playlist_track_picker.dart';
import 'widgets.dart';

class PlaylistEditorScreen extends StatefulWidget {
  const PlaylistEditorScreen({
    super.key,
    required this.app,
    required this.source,
  });
  final AppController app;
  final LibraryItem source;
  @override
  State<PlaylistEditorScreen> createState() => _PlaylistEditorScreenState();
}

class _PlaylistEditorScreenState extends State<PlaylistEditorScreen> {
  late final PlaylistEditSession session;
  bool _leaving = false;
  bool _allowPop = false;
  AppController get app => widget.app;
  @override
  void initState() {
    super.initState();
    session = app.editServerPlaylist(widget.source);
    unawaited(session.initialize());
  }

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    if (_leaving || session.busy) return;
    _leaving = true;
    try {
      if (!session.expired && session.draft?.hasChanges == true) {
        final discard = await confirm(
          context,
          'Выйти без сохранения?',
          'Изменения плейлиста не будут сохранены.',
          action: 'Не сохранять',
        );
        if (!discard || !mounted) return;
      }
      if (mounted) {
        setState(() => _allowPop = true);
        Navigator.pop(context);
      }
    } finally {
      _leaving = false;
    }
  }

  Future<void> _add() async {
    final tracks = await pickPlaylistTracks(context, app);
    if (mounted && tracks != null && tracks.isNotEmpty) {
      await perform(app, () async => session.append(tracks));
    }
  }

  Future<void> _removeMenu(PlaylistDraftEntry entry) async {
    final remove = await showActionSheet<bool>(
      context: context,
      title: entry.track.title,
      actions: (sheet) => [
        ListTile(
          leading: const Icon(Icons.delete_outline_rounded),
          title: const Text('Удалить из плейлиста'),
          onTap: () => Navigator.pop(sheet, true),
        ),
      ],
    );
    if (remove == true && mounted && !session.busy && !session.expired) {
      await perform(app, () async => session.remove(entry.id));
    }
  }

  Future<void> _saveLocal() async {
    final name = await askPlaylistName(
      context,
      title: 'Сохранить как локальный плейлист',
      initialName: widget.source.name,
    );
    if (name != null && mounted) {
      await perform(app, () async {
        await session.saveAsLocal(name);
      });
    }
  }

  Future<void> _saveServer() async {
    if (session.draft!.entries.isEmpty) {
      final clear = await confirm(
        context,
        'Очистить «${widget.source.name}»?',
        'Из плейлиста на сервере будут удалены все композиции. Сами аудиофайлы останутся.',
        action: 'Очистить',
      );
      if (!clear || !mounted || session.expired) return;
    }
    try {
      await session.saveToServer();
    } on ServerPlaylistConflict {
      if (!mounted || session.expired) return;
      final overwrite = await confirm(
        context,
        'Состав плейлиста отличается',
        'Плейлист изменился на сервере. Заменить его текущим составом из редактора?',
        action: 'Перезаписать',
      );
      if (overwrite && mounted && !session.expired) {
        await perform(app, () => session.saveToServer(overwriteChanged: true));
      }
    } catch (e) {
      app.message(AppController.friendly(e));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final entries = session.draft?.entries ?? <PlaylistDraftEntry>[];
      final editing =
          !session.loading &&
          !session.busy &&
          !session.expired &&
          session.draft != null;
      final info = session.expired
          ? 'Учётная запись изменилась. Откройте плейлист заново.'
          : session.isOffline()
          ? 'Офлайн: состав из сохранённых данных. Можно сохранить локально.'
          : entries.any((e) => e.track.isLocal)
          ? 'Файлы устройства можно сохранить только локально.'
          : session.remote.access == PlaylistEditAccess.denied
          ? 'Нет права записи на сервер. Можно сохранить локально.'
          : session.remote.access == PlaylistEditAccess.checking
          ? 'Проверяем права на сохранение…'
          : null;
      return PopScope(
        canPop:
            _allowPop ||
            (!session.busy &&
                (session.expired || session.draft?.hasChanges != true)),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_leave());
        },
        child: Scaffold(
          appBar: AppBar(
            leading: BackButton(onPressed: session.busy ? null : _leave),
            title: Text(
              widget.source.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                tooltip: 'Добавить композиции',
                icon: const Icon(Icons.playlist_add_rounded),
                onPressed: editing ? _add : null,
              ),
              PopupMenuButton<String>(
                tooltip: 'Сохранить плейлист',
                enabled: editing,
                icon: session.busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                onSelected: (value) =>
                    value == 'server' ? _saveServer() : _saveLocal(),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'server',
                    enabled: session.canSaveServer,
                    child: const Text('Сохранить удалённый плейлист'),
                  ),
                  const PopupMenuItem(
                    value: 'local',
                    child: Text('Как локальный плейлист…'),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Редактирование · ${trackCountLabel(entries.length)}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    AnimatedSize(
                      duration: motionDuration,
                      child: session.draft?.hasChanges == true
                          ? const Text('Не сохранено')
                          : session.savedMessage != null
                          ? Text(session.savedMessage!)
                          : const SizedBox.shrink(),
                    ),
                    AnimatedSize(
                      duration: motionDuration,
                      child: info == null
                          ? const SizedBox.shrink()
                          : Text(
                              info,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: session.loading
                    ? const Center(child: CircularProgressIndicator())
                    : session.error != null
                    ? EmptyState(
                        'Не удалось открыть плейлист',
                        subtitle: AppController.friendly(session.error!),
                        action: TextButton(
                          onPressed: session.initialize,
                          child: const Text('Повторить'),
                        ),
                      )
                    : session.expired
                    ? const EmptyState('Редактор недоступен')
                    : entries.isEmpty
                    ? EmptyState(
                        'В плейлисте нет композиций',
                        action: TextButton.icon(
                          onPressed: editing ? _add : null,
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('Добавить композиции'),
                        ),
                      )
                    : AbsorbPointer(
                        absorbing: session.busy,
                        child: AnimatedRows<PlaylistDraftEntry>(
                          items: entries,
                          idOf: (e) => e.id,
                          onReorder: session.move,
                          builder: (context, entry, index) => EditableTrackRow(
                            occurrenceId: entry.id,
                            track: entry.track,
                            position: index < 0 ? null : index + 1,
                            downloaded: app.isDownloaded(entry.track),
                            onMenu: () => _removeMenu(entry),
                            onRemove: () async {
                              if (!editing) return false;
                              session.remove(entry.id);
                              return true;
                            },
                            onMoveUp: editing && index > 0
                                ? () => session.move(index, index - 1)
                                : null,
                            onMoveDown:
                                editing &&
                                    index >= 0 &&
                                    index < entries.length - 1
                                ? () => session.move(index, index + 2)
                                : null,
                            dragHandle: index < 0
                                ? null
                                : ReorderableDragStartListener(
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
                                  ),
                          ),
                        ),
                      ),
              ),
              MiniPlayer(app: app),
            ],
          ),
        ),
      );
    },
  );
}
