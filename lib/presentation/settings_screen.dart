import 'package:flutter/material.dart';
import '../application/app_controller.dart';
import '../domain/download_group.dart';
import '../domain/volume_normalization.dart';
import 'actions.dart';
import 'widgets.dart';
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

  Future<void> _connectionDetails(BuildContext context) async {
    final session = app.library?.session;
    if (session == null) return;
    await appDialog<void>(
      context,
      AlertDialog(
        scrollable: true,
        title: const Text('Подключение'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              session.username,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            SelectableText(session.server),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: app,
    builder: (context, _) {
      if (!app.hasLibrary) return const Scaffold();
      final colors = Theme.of(context).colorScheme;
      return Scaffold(
        appBar: AppBar(title: const Text('Настройки')),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            _SettingsGroup(
              title: 'Библиотека',
              children: [
                if (!app.loggedIn)
                  ListTile(
                    leading: const Icon(Icons.login_rounded),
                    title: const Text('Подключить Jellyfin'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.push(
                      context,
                      slideRoute(LoginScreen(app: app)),
                    ),
                  )
                else
                  ListTile(
                    leading: const Icon(Icons.dns_outlined),
                    title: Text(app.library!.session.username),
                    subtitle: Text(
                      app.library!.session.server.replaceFirst(
                        RegExp(r'^https?://'),
                        '',
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => _connectionDetails(context),
                  ),
                ListTile(
                  leading: const Icon(Icons.audio_file_outlined),
                  title: const Text('Добавить музыку'),
                  subtitle: const Text('Аудиофайлы или папка из «Файлов»'),
                  onTap: app.importing
                      ? null
                      : () => importMusicMenu(context, app),
                ),
              ],
            ),
            _SettingsGroup(
              title: 'Воспроизведение',
              children: [
                ListTile(
                  leading: const Icon(Icons.volume_up_outlined),
                  title: const Text('Выравнивание громкости'),
                  subtitle: AnimatedSwitcher(
                    duration: motionDuration,
                    child: Align(
                      key: ValueKey(app.normalizationMode),
                      alignment: Alignment.centerLeft,
                      child: Text(_normalizationLabel(app.normalizationMode)),
                    ),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => _chooseNormalization(context),
                ),
                ListTile(
                  leading: const Icon(Icons.notifications_outlined),
                  title: const Text('Уведомления'),
                  subtitle: const Text('О недоступных композициях'),
                  onTap: () => perform(app, app.requestNotifications),
                ),
              ],
            ),
            if (app.loggedIn)
              _SettingsGroup(
                title: 'Мобильная сеть',
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.headphones_rounded),
                    title: const Text('Прослушивание'),
                    value: app.allowMobileStreaming,
                    onChanged: (value) =>
                        perform(app, () => app.setMobileStreaming(value)),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.download_outlined),
                    title: const Text('Скачивание'),
                    value: app.allowMobileDownloads,
                    onChanged: (value) =>
                        perform(app, () => app.setMobileDownloads(value)),
                  ),
                ],
              ),
            if (app.loggedIn)
              _SettingsGroup(
                title: 'Серверная библиотека',
                children: [
                  ListTile(
                    leading: const Icon(Icons.download_done_rounded),
                    title: const Text('Загрузки'),
                    subtitle: Text(
                      'На устройстве: ${trackCountLabel(app.downloads!.completedCount)}',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.push(
                      context,
                      slideRoute(DownloadsScreen(app: app)),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.sync_rounded),
                    title: const Text('Обновить библиотеку'),
                    onTap: app.refreshing
                        ? null
                        : () => perform(app, () async {
                            await app.refresh();
                            if (context.mounted &&
                                app.pendingChanges.isNotEmpty) {
                              await showChanges(context, app);
                            }
                          }),
                  ),
                ],
              ),
            if (app.loggedIn)
              _SettingsGroup(
                title: 'Данные и аккаунт',
                children: [
                  ListTile(
                    leading: const Icon(Icons.delete_sweep_outlined),
                    textColor: colors.error,
                    iconColor: colors.error,
                    title: const Text('Удалить все загрузки'),
                    onTap: () async {
                      if (await confirm(
                        context,
                        'Удалить все загрузки?',
                        'Удалим скачанную музыку только с этого устройства. Сервер, импорт, очередь и настройки сохранятся.',
                      )) {
                        await perform(app, () async {
                          await app.releaseLocalAudio();
                          await app.downloads!.clear();
                          app.message('Все загрузки удалены');
                        });
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.logout_rounded),
                    title: const Text('Выйти из аккаунта'),
                    onTap: () async {
                      if (await confirm(
                        context,
                        'Выйти из аккаунта?',
                        'Воспроизведение остановится. Загрузки будут доступны при следующем входе в этот аккаунт.',
                        action: 'Выйти',
                      )) {
                        await perform(app, app.logout);
                        if (context.mounted) {
                          Navigator.of(
                            context,
                          ).popUntil((route) => route.isFirst);
                        }
                      }
                    },
                  ),
                ],
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                'Simplefy · 0.5.2',
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
          child: Semantics(
            header: true,
            child: Text(
              title,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: ListTileTheme(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),

            minVerticalPadding: 8,
            minLeadingWidth: 24,
            horizontalTitleGap: 12,
            child: Column(children: children),
          ),
        ),
      ],
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
