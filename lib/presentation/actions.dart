import '../l10n/l10n.dart';
import 'package:flutter/material.dart';

import '../application/app_controller.dart';
import '../application/server_playlist_editor.dart';
import '../domain/library_item.dart';
import 'widgets.dart';
import 'action_sheet.dart';
import 'playlist_deletion_screen.dart';

Future<void> perform(AppController app, Future<void> Function() action) async {
  try {
    await action();
  } on Object catch (error) {
    app.message(AppController.friendly(error));
  }
}

Future<void> importMusicMenu(BuildContext context, AppController app) async {
  if (app.importing) return;
  final folder = await showActionSheet<bool>(
    context: context,
    title: context.l10n.addMusicFromFiles,
    message: context.l10n.aCopyWillBeSavedOnThis,
    actions: (sheet) => [
      ListTile(
        leading: const Icon(Icons.create_new_folder_outlined),
        title: Text(context.l10n.chooseAFolder),
        onTap: () => Navigator.pop(sheet, true),
      ),
      ListTile(
        leading: const Icon(Icons.audio_file_outlined),
        title: Text(context.l10n.chooseAudioFiles),
        onTap: () => Navigator.pop(sheet, false),
      ),
    ],
  );
  if (folder != null) await perform(app, () => app.importMusic(folder: folder));
}

Future<void> itemMenu(
  BuildContext context,
  AppController app,
  LibraryItem item,
) async {
  final choice = await showActionSheet<String>(
    context: context,
    title: item.isTrack ? item.title : item.displayName,
    actions: (sheet) => [
      _action(sheet, 'play', Icons.play_arrow_rounded, context.l10n.play),
      _action(
        sheet,
        'append',
        Icons.playlist_add_rounded,
        context.l10n.addToQueue,
      ),
      if (!item.isLocal &&
          (!item.isLocalPlaylist ||
              (app.loggedIn &&
                  app.localPlaylists.tracks(item.id).any((t) => !t.isLocal))))
        _action(
          sheet,
          'download',
          Icons.download_rounded,
          context.l10n.downloadToDevice,
        ),
      if (item.id == 'local:root')
        _action(sheet, 'import', Icons.add_rounded, context.l10n.addMusic),
      if (item.isPlaylist)
        _action(
          sheet,
          'deletePlaylist',
          Icons.delete_outline_rounded,
          context.l10n.deletePlaylists,
        ),
      if (!item.isLocalPlaylist &&
          (app.isDownloaded(item) ||
              app.downloads?.groups.containsKey(item.id) == true))
        _action(
          sheet,
          'remove',
          Icons.delete_outline_rounded,
          context.l10n.removeFromDevice,
        ),
    ],
  );
  if (choice == null || !context.mounted) return;
  await perform(app, () async {
    switch (choice) {
      case 'deletePlaylist':
        await Navigator.push(
          context,
          slideRoute(PlaylistDeletionScreen(app: app, initial: item)),
        );
      case 'play':
        await app.playGroup(item);
      case 'append':
        await app.addGroup(item);
      case 'download':
        app.message(AppMessage.preparingDownload);
        if (item.isLocalPlaylist) {
          final unique = {
            for (final track in app.localPlaylists.tracks(item.id))
              if (!track.isLocal) track.id: track,
          };
          for (final track in unique.values) {
            await app.downloads!.add(track);
          }
        } else {
          await app.downloads!.add(item);
        }
        app.message(AppMessage.downloadAdded);
      case 'import':
        if (context.mounted) await importMusicMenu(context, app);
      case 'remove':
        if (await confirm(
          context,
          item.isLocal
              ? context.l10n.deleteImportedCopy
              : context.l10n.deleteDownload2,
          item.isLocal
              ? context.l10n.onlyTheCopyInThisAppWill
              : context.l10n.serverMusicAndTheQueueWillStay,
        )) {
          await removeLocal(app, item);
        }
    }
  });
}

Widget _action(
  BuildContext context,
  String value,
  IconData icon,
  String label,
) => ListTile(
  leading: Icon(
    icon,
    color: value == 'remove' || value == 'deletePlaylist'
        ? Theme.of(context).colorScheme.error
        : null,
  ),
  title: Text(
    label,
    style: TextStyle(
      color: value == 'remove' || value == 'deletePlaylist'
          ? Theme.of(context).colorScheme.error
          : null,
    ),
  ),
  onTap: () => Navigator.pop(context, value),
);

Future<void> removeLocal(AppController app, LibraryItem item) async {
  if (item.isLocal) {
    await app.removeImported(item);
    app.message(AppMessage.importedCopyRemovedTheOriginalFilesAre);
    return;
  }
  final downloads = app.downloads!;
  final group = downloads.groups[item.id];
  final tracks = app.downloadSelection(item);
  final otherReferences = group == null
      ? <String>{}
      : downloads.groups.values
            .where((g) => g.source.id != group.source.id)
            .expand((g) => g.tracks)
            .map((t) => t.id)
            .toSet();
  if (tracks.any(
    (t) =>
        t.id == app.queue.current?.track.id && !otherReferences.contains(t.id),
  )) {
    await app.releaseLocalAudio();
  }
  if (group != null) {
    await downloads.removeGroup(item.id);
  } else {
    await downloads.removeTracks(tracks.map((t) => t.id).toSet());
  }
  app.message(AppMessage.downloadRemovedFromThisDevice);
}

Future<void> showChanges(BuildContext context, AppController app) async {
  final changes = List.of(app.pendingChanges);
  if (changes.isEmpty) return;
  final update = await appDialog<bool>(
    context,
    AlertDialog(
      title: Text(context.l10n.downloadsHaveChanged2),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(context.l10n.updateTheDownloadedContentsToMatchThe),
            const SizedBox(height: 16),
            for (final change in changes)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '${change.before.source.displayName}\n${context.l10n.addedRemoved((change.added).toString(), (change.removed).toString())}',
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.later),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(context.l10n.update),
        ),
      ],
    ),
  );
  if (update == true) {
    await perform(app, () async {
      final removed = changes
          .expand(
            (c) => c.before.tracks.where(
              (t) => !c.after.tracks.any((a) => a.id == t.id),
            ),
          )
          .map((t) => t.id)
          .toSet();
      if (removed.contains(app.queue.current?.track.id)) {
        await app.releaseLocalAudio();
      }
      await app.applyChanges();
      app.message(AppMessage.downloadsUpdated);
    });
  }
}

Future<void> saveQueuePlaylist(
  BuildContext context,
  AppController app, {
  required bool overwrite,
}) async {
  if (overwrite) {
    await perform(app, () => app.saveQueueAsPlaylist(overwrite: true));
    return;
  }
  final name = await askPlaylistName(context);
  if (name != null) {
    await perform(app, () => app.saveQueueAsPlaylist(name: name));
  }
}

Future<String?> askPlaylistName(
  BuildContext context, {
  String? title,
  String initialName = '',
}) => appDialog<String>(
  context,
  _PlaylistNameDialog(
    title: title ?? context.l10n.saveQueueAsPlaylist,
    initialName: initialName,
  ),
);

class _PlaylistNameDialog extends StatefulWidget {
  const _PlaylistNameDialog({required this.title, required this.initialName});
  final String title;
  final String initialName;
  @override
  State<_PlaylistNameDialog> createState() => _PlaylistNameDialogState();
}

class _PlaylistNameDialogState extends State<_PlaylistNameDialog> {
  late final _name = TextEditingController(text: widget.initialName);
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _name.text.trim();
    if (value.isNotEmpty) Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.title),
    content: TextField(
      controller: _name,
      autofocus: true,
      maxLength: 100,
      decoration: InputDecoration(labelText: context.l10n.playlistName),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(context.l10n.cancel),
      ),
      FilledButton(onPressed: _submit, child: Text(context.l10n.save)),
    ],
  );
}

Future<void> createServerQueuePlaylist(
  BuildContext context,
  AppController app,
) async {
  final name = await askPlaylistName(
    context,
    title: context.l10n.saveAsNewServerPlaylist,
  );
  if (name != null) {
    await perform(app, () => app.createServerPlaylistFromQueue(name));
  }
}

Future<void> saveServerQueuePlaylist(
  BuildContext context,
  AppController app,
) async {
  final target = app.serverPlaylist.item;
  final identity = app.libraryIdentity;
  if (target == null) return;
  if (app.queue.entries.isEmpty) {
    final clear = await appDialog<bool>(
      context,
      AlertDialog(
        title: Text(context.l10n.clear2((target.displayName).toString())),
        content: Text(context.l10n.allTracksWillBeRemovedFromThis),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.clear),
          ),
        ],
      ),
    );
    if (clear != true ||
        !context.mounted ||
        (app.serverPlaylist.item?.id != target.id ||
            app.libraryIdentity != identity)) {
      return;
    }
  }
  try {
    await app.saveQueueToServer();
  } on ServerPlaylistConflict {
    if (!context.mounted) return;
    final overwrite = await appDialog<bool>(
      context,
      AlertDialog(
        title: Text(context.l10n.playlistContentsHaveChanged),
        content: Text(
          context.l10n.replaceTheContentsOfWithTheCurrent(
            (target.displayName).toString(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.l10n.overwrite),
          ),
        ],
      ),
    );
    if (overwrite == true &&
        app.serverPlaylist.item?.id == target.id &&
        app.libraryIdentity == identity) {
      await perform(app, () => app.saveQueueToServer(overwriteChanged: true));
    }
  } on Object catch (error) {
    app.message(AppController.friendly(error));
  }
}
