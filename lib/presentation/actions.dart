import 'package:flutter/material.dart';

import '../application/app_controller.dart';
import '../application/server_playlist_editor.dart';
import '../domain/library_item.dart';
import 'widgets.dart';

Future<void> perform(AppController app, Future<void> Function() action) async {
  try {
    await action();
  } catch (error) {
    app.message(AppController.friendly(error));
  }
}

Future<void> importMusicMenu(BuildContext context, AppController app) async {
  if (app.importing) return;
  final folder = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('Добавить музыку из «Файлов»'),
          ),
          ListTile(
            leading: const Icon(Icons.create_new_folder_outlined),
            title: const Text('Выбрать папку'),
            onTap: () => Navigator.pop(sheet, true),
          ),
          ListTile(
            leading: const Icon(Icons.audio_file_outlined),
            title: const Text('Выбрать аудиофайлы'),
            onTap: () => Navigator.pop(sheet, false),
          ),
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'Сохраним копию на этом устройстве. Исходные файлы не изменятся.',
            ),
          ),
        ],
      ),
    ),
  );
  if (folder != null) await perform(app, () => app.importMusic(folder: folder));
}

Future<void> itemMenu(
  BuildContext context,
  AppController app,
  LibraryItem item,
) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text(
              item.isTrack ? item.title : item.name,
              maxLines: 2,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          _action(sheet, 'play', Icons.play_arrow_rounded, 'Проиграть'),
          _action(
            sheet,
            'append',
            Icons.playlist_add_rounded,
            'Добавить в очередь',
          ),
          if (!item.isLocal &&
              (!item.isLocalPlaylist ||
                  (app.loggedIn &&
                      app.localPlaylists
                          .tracks(item.id)
                          .any((t) => !t.isLocal))))
            _action(
              sheet,
              'download',
              Icons.download_rounded,
              'Скачать на устройство',
            ),
          if (item.id == 'local:root')
            _action(sheet, 'import', Icons.add_rounded, 'Добавить музыку'),
          if (item.isLocalPlaylist)
            _action(
              sheet,
              'deletePlaylist',
              Icons.delete_outline_rounded,
              'Удалить локальный плейлист',
            ),
          if (!item.isLocalPlaylist &&
              (app.isDownloaded(item) ||
                  app.downloads?.groups.containsKey(item.id) == true))
            _action(
              sheet,
              'remove',
              Icons.delete_outline_rounded,
              'Удалить с устройства',
            ),
          const SizedBox(height: 12),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  await perform(app, () async {
    switch (choice) {
      case 'deletePlaylist':
        if (await confirm(
          context,
          'Удалить локальный плейлист?',
          'Музыка, загрузки и текущая очередь сохранятся.',
        )) {
          await app.deleteLocalPlaylist(item);
        }
      case 'play':
        await app.playGroup(item);
      case 'append':
        await app.addGroup(item);
      case 'download':
        app.message('Подготавливаем загрузку…');
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
        app.message('Загрузка добавлена');
      case 'import':
        if (context.mounted) await importMusicMenu(context, app);
      case 'remove':
        if (await confirm(
          context,
          item.isLocal ? 'Удалить импортированную копию?' : 'Удалить загрузку?',
          item.isLocal
              ? 'Удалится только копия в приложении. Исходные файлы в «Файлах» сохранятся.'
              : 'Удаляются только файлы на устройстве. Сервер и очередь сохранятся. '
                    'Если удаляется играющий локальный файл, воспроизведение будет на паузе.',
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
  leading: Icon(icon),
  title: Text(label),
  onTap: () => Navigator.pop(context, value),
);

Future<void> removeLocal(AppController app, LibraryItem item) async {
  if (item.isLocal) {
    await app.removeImported(item);
    app.message('Импортированная копия удалена. Исходные файлы сохранены.');
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
  app.message('Загрузка удалена с устройства');
}

Future<void> showChanges(BuildContext context, AppController app) async {
  final changes = List.of(app.pendingChanges);
  if (changes.isEmpty) return;
  final update = await appDialog<bool>(
    context,
    AlertDialog(
      title: const Text('Загрузки изменились'),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView(
          shrinkWrap: true,
          children: [
            const Text(
              'Обновить содержимое на устройстве в соответствии с сервером?',
            ),
            const SizedBox(height: 16),
            for (final change in changes)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  '${change.before.source.name}\n'
                  'Добавлено: ${change.added} · Удалено: ${change.removed}',
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Позже'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: const Text('Обновить'),
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
      app.message('Загрузки обновлены');
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
  final text = TextEditingController();
  final name = await appDialog<String>(
    context,
    AlertDialog(
      title: const Text('Сохранить очередь как плейлист'),
      content: TextField(
        controller: text,
        autofocus: true,
        maxLength: 100,
        decoration: const InputDecoration(labelText: 'Название плейлиста'),
        onSubmitted: (value) {
          if (value.trim().isNotEmpty) Navigator.pop(context, value.trim());
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () {
            if (text.text.trim().isNotEmpty) {
              Navigator.pop(context, text.text.trim());
            }
          },
          child: const Text('Сохранить'),
        ),
      ],
    ),
  );
  // The dialog animates out while its text field still owns the controller.
  await Future<void>.delayed(motionDuration);
  text.dispose();
  if (name != null) {
    await perform(app, () => app.saveQueueAsPlaylist(name: name));
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
        title: Text('Очистить «${target.name}»?'),
        content: const Text(
          'Из плейлиста на сервере будут удалены все композиции. Сами аудиофайлы останутся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Очистить'),
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
        title: const Text('Состав плейлиста отличается'),
        content: Text(
          'Заменить текущий состав «${target.name}» содержимым очереди?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Перезаписать'),
          ),
        ],
      ),
    );
    if (overwrite == true &&
        app.serverPlaylist.item?.id == target.id &&
        app.libraryIdentity == identity) {
      await perform(app, () => app.saveQueueToServer(overwriteChanged: true));
    }
  } catch (error) {
    app.message(AppController.friendly(error));
  }
}
