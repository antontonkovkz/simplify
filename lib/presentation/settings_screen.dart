import 'package:flutter/material.dart';
import '../application/app_controller.dart';
import '../domain/download_group.dart';
import '../domain/volume_normalization.dart';
import 'actions.dart';
import 'widgets.dart';
import 'brand_mark.dart';
import 'login_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.app});
  final AppController app;
  String _normalizationLabel(VolumeNormalizationMode mode) => switch (mode) {
    VolumeNormalizationMode.off => 'Выключено',
    VolumeNormalizationMode.track => 'По композициям',
    VolumeNormalizationMode.album => 'По альбомам',
  };

  Future<void> _chooseNormalization(BuildContext context) async {
    final mode = await appDialog<VolumeNormalizationMode>(
      context,
      SimpleDialog(
        title: const Text('Выравнивание громкости'),
        children: [
          for (final mode in VolumeNormalizationMode.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, mode),
              child: Semantics(
                selected: mode == app.normalizationMode,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        mode == app.normalizationMode
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(_normalizationLabel(mode))),
                    ],
                  ),
                ),
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(24, 12, 24, 8),
            child: Text(
              'Используются данные громкости Jellyfin. Без них композиция играет с исходной громкостью. Усиление тихих записей пока не применяется.',
            ),
          ),
        ],
      ),
    );
    if (mode != null) {
      await perform(app, () => app.setVolumeNormalization(mode));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) => !app.hasLibrary
        ? const Scaffold()
        : Scaffold(
            appBar: AppBar(title: const Text('Настройки')),
            body: ListView(
              children: [
                if (!app.loggedIn)
                  ListTile(
                    leading: const Icon(Icons.login_rounded),
                    title: const Text('Подключить Jellyfin'),
                    onTap: () => Navigator.push(
                      context,
                      slideRoute(LoginScreen(app: app)),
                    ),
                  ),
                if (app.loggedIn)
                  ListTile(
                    title: const Text('Подключение'),
                    subtitle: Text(
                      '${app.library!.session.server}\n${app.library!.session.username}',
                    ),
                    leading: const Icon(Icons.dns_outlined),
                  ),
                ListTile(
                  leading: const Icon(Icons.audio_file_outlined),
                  title: const Text('Добавить музыку из Файлов'),
                  subtitle: const Text('Аудиофайлы или папка с музыкой'),
                  onTap: app.importing
                      ? null
                      : () => importMusicMenu(context, app),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.volume_up_outlined),
                  title: const Text('Выравнивание громкости'),
                  subtitle: AnimatedSwitcher(
                    duration: motionDuration,
                    child: Text(
                      _normalizationLabel(app.normalizationMode),
                      key: ValueKey(app.normalizationMode),
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _chooseNormalization(context),
                ),
                if (app.loggedIn)
                  SwitchListTile(
                    title: const Text('Прослушивание через мобильную сеть'),
                    value: app.allowMobileStreaming,
                    onChanged: (v) =>
                        perform(app, () => app.setMobileStreaming(v)),
                  ),
                if (app.loggedIn)
                  SwitchListTile(
                    title: const Text('Скачивание через мобильную сеть'),
                    value: app.allowMobileDownloads,
                    onChanged: (v) =>
                        perform(app, () => app.setMobileDownloads(v)),
                  ),
                ListTile(
                  leading: const Icon(Icons.notifications_outlined),
                  title: const Text('Уведомления о недоступных треках'),
                  subtitle: const Text('Разрешить системные уведомления'),
                  onTap: () => perform(app, app.requestNotifications),
                ),
                const Divider(),
                if (app.loggedIn)
                  ListTile(
                    leading: const Icon(Icons.download_done_rounded),
                    title: const Text('Загрузки'),
                    subtitle: Text(
                      'На устройстве: ${app.downloads!.completedCount} композиций',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.push(
                      context,
                      slideRoute(DownloadsScreen(app: app)),
                    ),
                  ),
                if (app.loggedIn)
                  ListTile(
                    leading: const Icon(Icons.sync_rounded),
                    title: const Text('Обновить библиотеку'),
                    onTap: () => perform(app, () async {
                      await app.refresh();
                      if (context.mounted && app.pendingChanges.isNotEmpty) {
                        await showChanges(context, app);
                      }
                    }),
                  ),
                if (app.loggedIn)
                  ListTile(
                    leading: const Icon(Icons.delete_sweep_outlined),
                    title: const Text('Удалить все загрузки'),
                    onTap: () async {
                      if (await confirm(
                        context,
                        'Удалить все загрузки?',
                        'Скачанная с сервера музыка будет удалена только с устройства. Импортированные файлы, очередь и настройки сохранятся.',
                      )) {
                        await perform(app, () async {
                          await app.releaseLocalAudio();
                          await app.downloads!.clear();
                          app.message('Все загрузки удалены');
                        });
                      }
                    },
                  ),
                const Divider(),
                if (app.loggedIn)
                  ListTile(
                    leading: const Icon(Icons.logout_rounded),
                    title: const Text('Выйти из учётной записи'),
                    subtitle: const Text(
                      'Загрузки сохранятся до следующего входа в эту учётную запись',
                    ),
                    onTap: () async {
                      if (await confirm(
                        context,
                        'Выйти?',
                        'Воспроизведение будет остановлено.',
                        action: 'Выйти',
                      )) {
                        await perform(app, app.logout);
                        if (context.mounted) {
                          Navigator.of(context).popUntil((r) => r.isFirst);
                        }
                      }
                    },
                  ),
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    children: [
                      BrandMark(size: 72),
                      SizedBox(height: 12),
                      Text('Simplefy · 0.5.0', textAlign: TextAlign.center),
                      SizedBox(height: 8),
                      Text(
                        'Just music. Just play.\nYour music. Your way.',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
  );
}

class DownloadsScreen extends StatelessWidget {
  const DownloadsScreen({super.key, required this.app});
  final AppController app;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      if (!app.loggedIn) return const Scaffold();
      final groups = app.downloads!.groups.values.toList();
      return Scaffold(
        appBar: AppBar(title: const Text('Загрузки')),
        body: groups.isEmpty
            ? const EmptyState(
                'Загрузок пока нет',
                subtitle: 'Скачайте музыку через меню.',
                icon: Icons.download_outlined,
              )
            : AnimatedRows<DownloadGroup>(
                items: groups,
                idOf: (group) => group.source.id,
                builder: (context, group, index) {
                  final ids = group.tracks.map((t) => t.id).toSet();
                  final done = ids.where(app.downloads!.contains).length;
                  final failed = ids
                      .where((id) => app.downloads!.errors.containsKey(id))
                      .length;
                  final value = ids.isEmpty
                      ? 0.0
                      : ids.fold<double>(
                              0,
                              (sum, id) =>
                                  sum +
                                  (app.downloads!.contains(id)
                                      ? 1
                                      : app.downloads!.progress[id] ?? 0),
                            ) /
                            ids.length;
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          children: [
                            ListTile(
                              title: Text(
                                group.source.isTrack
                                    ? group.source.title
                                    : group.source.name,
                              ),
                              subtitle: Text(
                                '$done из ${ids.length} скачано${failed > 0 ? ' · Ошибок: $failed' : ''}',
                              ),
                              leading: Icon(
                                group.source.isTrack
                                    ? Icons.music_note_rounded
                                    : Icons.folder_rounded,
                              ),
                              trailing: IconButton(
                                tooltip: 'Удалить загрузку',
                                icon: const Icon(Icons.delete_outline_rounded),
                                onPressed: () async {
                                  if (await confirm(
                                    context,
                                    'Удалить загрузку?',
                                    'Общие файлы, нужные другим загрузкам, сохранятся.',
                                  )) {
                                    await perform(
                                      app,
                                      () => removeLocal(app, group.source),
                                    );
                                  }
                                },
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: TweenAnimationBuilder<double>(
                                tween: Tween(begin: 0, end: value),
                                duration: motionDuration,
                                builder: (context, v, _) =>
                                    LinearProgressIndicator(value: v),
                              ),
                            ),
                            if (done < ids.length)
                              TextButton.icon(
                                onPressed: () => perform(
                                  app,
                                  () => app.downloads!.apply(group),
                                ),
                                icon: const Icon(Icons.refresh_rounded),
                                label: const Text('Повторить незавершённые'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
      );
    },
  );
}
