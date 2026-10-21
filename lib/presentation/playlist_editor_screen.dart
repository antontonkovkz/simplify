import '../l10n/l10n.dart';
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
          context.l10n.discardChanges,
          context.l10n.yourPlaylistChangesWillNotBeSaved,
          action: context.l10n.discard,
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
          title: Text(context.l10n.removeFromPlaylist),
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
      title: context.l10n.saveAsALocalPlaylist,
      initialName: widget.source.displayName,
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
        context.l10n.clear2((widget.source.displayName).toString()),
        context.l10n.allTracksWillBeRemovedFromThis,
        action: context.l10n.clear,
      );
      if (!clear || !mounted || session.expired) return;
    }
    try {
      await session.saveToServer();
    } on ServerPlaylistConflict {
      if (!mounted || session.expired) return;
      final overwrite = await confirm(
        context,
        context.l10n.playlistContentsHaveChanged,
        context.l10n.thisPlaylistChangedOnTheServerReplace,
        action: context.l10n.overwrite,
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
          ? context.l10n.theAccountHasChangedOpenThePlaylist
          : session.isOffline()
          ? context.l10n.offlineShowingSavedContentsYouCanSave
          : entries.any((e) => e.track.isLocal)
          ? context.l10n.tracksFromThisDeviceCanOnlyBe
          : session.remote.access == PlaylistEditAccess.denied
          ? context.l10n.youCannotSaveChangesToTheServer
          : session.remote.access == PlaylistEditAccess.checking
          ? context.l10n.checkingSavePermissions
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
              widget.source.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                tooltip: context.l10n.addTracks,
                icon: const Icon(Icons.playlist_add_rounded),
                onPressed: editing ? _add : null,
              ),
              PopupMenuButton<String>(
                tooltip: context.l10n.savePlaylist,
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
                    child: Text(context.l10n.saveServerPlaylist),
                  ),
                  PopupMenuItem(
                    value: 'local',
                    child: Text(context.l10n.asALocalPlaylist),
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
                      context.l10n.editing(
                        (trackCountLabel(entries.length)).toString(),
                      ),
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    AnimatedSize(
                      duration: motionDuration,
                      child: session.draft?.hasChanges == true
                          ? Text(context.l10n.unsaved)
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
                        context.l10n.couldNotOpenThePlaylist,
                        subtitle: AppController.friendly(session.error!),
                        action: TextButton(
                          onPressed: session.initialize,
                          child: Text(context.l10n.retry),
                        ),
                      )
                    : session.expired
                    ? EmptyState(context.l10n.editorUnavailable)
                    : entries.isEmpty
                    ? EmptyState(
                        context.l10n.thisPlaylistHasNoTracks,
                        action: TextButton.icon(
                          onPressed: editing ? _add : null,
                          icon: const Icon(Icons.add_rounded),
                          label: Text(context.l10n.addTracks),
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
                                    child: Tooltip(
                                      message: context.l10n.reorder,
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
