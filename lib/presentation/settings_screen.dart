import '../l10n/l10n.dart';
import 'package:flutter/material.dart';
import '../application/app_controller.dart';
import 'language_picker.dart';
import '../domain/download_group.dart';
import '../domain/volume_normalization.dart';
import 'actions.dart';
import 'widgets.dart';
import 'login_screen.dart';
import 'downloaded_tracks_screen.dart';
import 'group_play_button.dart';
import 'play_group_action.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.app});
  final AppController app;
  String _normalizationLabel(VolumeNormalizationMode mode) => switch (mode) {
    VolumeNormalizationMode.off => L10n.current.off,
    VolumeNormalizationMode.track => L10n.current.byTrack,
    VolumeNormalizationMode.album => L10n.current.byAlbum,
  };

  Future<void> _chooseNormalization(BuildContext context) async {
    final mode = await appDialog<VolumeNormalizationMode>(
      context,
      SimpleDialog(
        title: Text(context.l10n.volumeNormalization),
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
          Padding(
            padding: EdgeInsets.fromLTRB(24, 12, 24, 8),
            child: Text(
              context.l10n.usesLoudnessMetadataFromJellyfinTracksWithout,
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
        title: Text(context.l10n.connection),
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
            child: Text(context.l10n.close),
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
        appBar: AppBar(title: Text(context.l10n.settings)),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            _SettingsGroup(
              title: context.l10n.library,
              children: [
                if (!app.loggedIn)
                  ListTile(
                    leading: const Icon(Icons.login_rounded),
                    title: Text(context.l10n.connectToJellyfin),
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
                  title: Text(context.l10n.addMusic),
                  subtitle: Text(context.l10n.audioFilesOrAFolderFromFiles),
                  onTap: app.importing
                      ? null
                      : () => importMusicMenu(context, app),
                ),
              ],
            ),
            ListTile(
              leading: const Icon(Icons.language_rounded),
              title: Text(context.l10n.language),
              subtitle: Text(languageLabel(context, app.languages.preference)),
              onTap: () => chooseAppLanguage(context, app),
            ),
            _SettingsGroup(
              title: context.l10n.playback,
              children: [
                ListTile(
                  leading: const Icon(Icons.volume_up_outlined),
                  title: Text(context.l10n.volumeNormalization),
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
                  title: Text(context.l10n.notifications),
                  subtitle: Text(context.l10n.forUnavailableTracks),
                  onTap: () => perform(app, app.requestNotifications),
                ),
              ],
            ),
            if (app.loggedIn)
              _SettingsGroup(
                title: context.l10n.mobileData,
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.headphones_rounded),
                    title: Text(context.l10n.streaming),
                    value: app.allowMobileStreaming,
                    onChanged: (value) =>
                        perform(app, () => app.setMobileStreaming(value)),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.download_outlined),
                    title: Text(context.l10n.downloads2),
                    value: app.allowMobileDownloads,
                    onChanged: (value) =>
                        perform(app, () => app.setMobileDownloads(value)),
                  ),
                ],
              ),
            if (app.loggedIn)
              _SettingsGroup(
                title: context.l10n.serverLibrary,
                children: [
                  ListTile(
                    leading: const Icon(Icons.download_done_rounded),
                    title: Text(context.l10n.downloads),
                    subtitle: Text(
                      context.l10n.onDeviceTracks(
                        (trackCountLabel(
                          app.downloads!.completedCount,
                        )).toString(),
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.push(
                      context,
                      slideRoute(DownloadsScreen(app: app)),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.library_music_outlined),
                    title: Text(context.l10n.downloadedSongs),
                    subtitle: Text(context.l10n.viewAndDeleteIndividualTracks),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.push(
                      context,
                      slideRoute(DownloadedTracksScreen(app: app)),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.sync_rounded),
                    title: Text(context.l10n.refreshLibrary),
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
                title: context.l10n.dataAndAccount,
                children: [
                  ListTile(
                    leading: const Icon(Icons.delete_sweep_outlined),
                    textColor: colors.error,
                    iconColor: colors.error,
                    title: Text(context.l10n.deleteAllDownloads),
                    onTap: () async {
                      if (await confirm(
                        context,
                        context.l10n.deleteAllDownloads2,
                        context.l10n.downloadedMusicWillOnlyBeDeletedFrom,
                      )) {
                        await perform(app, () async {
                          await app.releaseLocalAudio();
                          await app.downloads!.clear();
                          app.message(AppMessage.allDownloadsDeleted);
                        });
                      }
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.logout_rounded),
                    title: Text(context.l10n.signOut2),
                    onTap: () async {
                      if (await confirm(
                        context,
                        context.l10n.signOut3,
                        context.l10n.playbackWillStopYourDownloadsWillBe,
                        action: context.l10n.signOut,
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
                'Simplefy · 0.7.0',
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
        appBar: AppBar(title: Text(context.l10n.downloads)),
        body: groups.isEmpty
            ? EmptyState(
                context.l10n.noDownloadsYet,
                subtitle: context.l10n.downloadMusicFromAnItemSMenu,
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
                                    : group.source.displayName,
                              ),
                              subtitle: Text(
                                context.l10n.ofDownloaded(
                                  (done).toString(),
                                  (ids.length).toString(),
                                  (failed > 0
                                          ? context.l10n.errors(
                                              (failed).toString(),
                                            )
                                          : '')
                                      .toString(),
                                ),
                              ),
                              leading: Icon(
                                group.source.isTrack
                                    ? Icons.music_note_rounded
                                    : Icons.folder_rounded,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: context.l10n.deleteDownload,
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                    ),
                                    onPressed: () async {
                                      if (await confirm(
                                        context,
                                        context.l10n.deleteDownload2,
                                        context
                                            .l10n
                                            .sharedFilesNeededByOtherDownloadsWill,
                                      )) {
                                        await perform(
                                          app,
                                          () => removeLocal(app, group.source),
                                        );
                                      }
                                    },
                                  ),
                                  if (!group.source.isTrack)
                                    GroupPlayButton(
                                      name: group.source.displayName,
                                      onPlay: () => playGroupAndOpenQueue(
                                        context,
                                        app,
                                        group.source,
                                      ),
                                    ),
                                ],
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
                                label: Text(
                                  context.l10n.retryUnfinishedDownloads,
                                ),
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
