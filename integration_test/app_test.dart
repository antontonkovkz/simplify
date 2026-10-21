import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:simplefy/main.dart' as ui;
import 'package:simplefy/domain/download_group.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/application/ports.dart';
import 'package:simplefy/presentation/library_screens.dart';
import 'package:simplefy/presentation/player_screens.dart';
import 'package:simplefy/presentation/widgets.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized()
      .platformDispatcher
      .localeTestValue = const Locale(
    'ru',
  );
  testWidgets(
    'Jellyfin UI, real playback, downloads, shared assets and saved state',
    (tester) async {
      const server = String.fromEnvironment('TEST_SERVER');
      const username = String.fromEnvironment('TEST_USERNAME');
      const password = String.fromEnvironment('TEST_PASSWORD');
      expect(
        server.isNotEmpty && username.isNotEmpty && password.isNotEmpty,
        true,
        reason: 'Supply private test definitions outside the project.',
      );
      final network = TestNetwork();
      final controller = await ui.createController(network: network);
      runApp(ui.SimplefyApp(app: controller));
      unawaited(controller.initialize());
      Future<void> until(bool Function() ready, {int seconds = 45}) async {
        final end = DateTime.now().add(Duration(seconds: seconds));
        while (DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 200));
          await Future<void>.delayed(const Duration(milliseconds: 150));
          if (ready()) {
            await tester.pump(const Duration(milliseconds: 350));
            if (ready()) return;
          }
        }
        expect(
          ready(),
          true,
          reason: 'Timed out waiting for integration checkpoint',
        );
      }

      await until(() => find.byType(ui.SimplefyApp).evaluate().isNotEmpty);
      final app = tester
          .widget<ui.SimplefyApp>(find.byType(ui.SimplefyApp))
          .app;
      await until(() => app.initialized);
      if (app.loggedIn) {
        await app.logout();
        await tester.pump(const Duration(milliseconds: 400));
      }
      await until(() => find.byType(TextField).evaluate().length == 3);
      await tester.enterText(find.byType(TextField).at(0), server);
      await tester.enterText(find.byType(TextField).at(1), username);
      await tester.enterText(find.byType(TextField).at(2), password);
      await tester.tap(find.text('Подключиться'));
      await until(
        () =>
            (app.loggedIn && !app.refreshing) ||
            find
                .textContaining('Не удалось выполнить операцию')
                .evaluate()
                .isNotEmpty,
      );
      expect(
        app.loggedIn,
        true,
        reason: 'Connection failed; see sanitized stack trace',
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Коллекции'), findsWidgets);
      final collections = await app.root(false);
      expect(collections, isNotEmpty);
      await until(
        () => find.text(collections.first.name).evaluate().isNotEmpty,
      );
      await tester.tap(find.text(collections.first.name).first);
      await until(() => find.byType(LibraryScreen).evaluate().isNotEmpty);
      final folders = await app.children(collections.first);
      await until(() => find.text(folders.first.name).evaluate().isNotEmpty);
      expect(folders.any((f) => !f.isTrack), true);
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Плейлисты').last);
      final playlists = await app.root(true);
      await until(() => find.text(playlists.first.name).evaluate().isNotEmpty);
      await tester.tap(find.text(playlists.first.name).first);
      final tracks = await app.tracks(playlists.first);
      expect(tracks.length, greaterThan(2));
      await until(
        () => find
            .widgetWithText(ItemTile, tracks[1].title)
            .evaluate()
            .isNotEmpty,
      );
      await app.audio.player.setVolume(0);
      await tester.tap(find.widgetWithText(ItemTile, tracks[1].title).first);
      await until(
        () => app.isPlaying && app.queue.current?.track.id == tracks[1].id,
      );
      expect(app.queue.entries.length, tracks.length);
      expect(app.queue.entries.map((e) => e.track.id), tracks.map((e) => e.id));
      expect(app.queue.canPrevious, true);
      await app.next(false);
      await until(
        () => app.isPlaying && app.queue.current?.track.id == tracks[2].id,
      );
      await app.previous();
      expect(app.queue.current!.track.id, tracks[1].id);
      await tester.tap(find.byTooltip('Поиск').first);
      await until(() => find.byType(SearchScreen).evaluate().isNotEmpty);
      await tester.enterText(find.byType(TextField).first, tracks[1].fileName);
      await until(
        () => find
            .widgetWithText(ItemTile, tracks[1].title)
            .evaluate()
            .isNotEmpty,
      );
      await tester.tap(find.widgetWithText(ItemTile, tracks[1].title).first);
      await until(
        () => app.isPlaying && app.queue.current?.track.id == tracks[1].id,
      );
      expect(
        app.queue.entries.length,
        tracks.length,
        reason: 'Playlist search keeps full playlist',
      );
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('Очередь').first);
      await until(() => find.byType(QueueScreen).evaluate().isNotEmpty);
      final current = app.queue.current!;
      final index = app.queue.entries.indexWhere((e) => e.id == current.id);
      await tester.tap(find.byTooltip('Удалить из очереди').at(index));
      await until(
        () => find.text('Удалить и дать доиграть').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Удалить и дать доиграть'));
      await until(() => app.queue.detached);
      expect(app.isPlaying, true);
      await app.next(false);
      expect(app.queue.current!.track.id, tracks[2].id);
      final order = app.queue.entries.map((e) => e.id).toList();
      app.setShuffle(true);
      final before = app.queue.current!.id;
      await app.next(false);
      await app.previous();
      expect(app.queue.current!.id, before);
      expect(app.queue.entries.map((e) => e.id), order);
      app.setShuffle(false);
      await app.pause();
      debugPrint(
        'CHECKPOINT: streaming, playlist search, queue removal and shuffle passed',
      );

      final all = await app.tracks(collections.first);
      final candidates =
          all
              .where(
                (t) =>
                    t.durationMs > 10000 &&
                    (t.fileName.toLowerCase().endsWith('.mp3') ||
                        t.fileName.toLowerCase().endsWith('.m4a')),
              )
              .toList()
            ..sort((a, b) => a.durationMs.compareTo(b.durationMs));
      final downloaded = candidates.isNotEmpty ? candidates.first : all.first;
      if (candidates.length >= 2) {
        final upcoming = candidates[1];
        await app.playTracks([downloaded, upcoming]);
        await until(
          () => app.preloader?.localPath(upcoming.id) != null,
          seconds: 120,
        );
        expect(
          app.downloads!.contains(upcoming.id),
          false,
          reason: 'Speculative caching is separate from explicit downloads',
        );
        await app.seek(const Duration(seconds: 8));
        network.set(NetworkKind.offline);
        await until(() => app.waitingForNetwork && !app.isPlaying);
        final saved = app.position.inMilliseconds;
        network.set(NetworkKind.unmetered);
        await until(() => app.isPlaying && !app.waitingForNetwork);
        expect(app.queue.current!.track.id, downloaded.id);
        expect(app.position.inMilliseconds, greaterThanOrEqualTo(saved - 500));
        await until(
          () => app.preloader?.localPath(upcoming.id) != null,
          seconds: 120,
        );
        network.set(NetworkKind.offline);
        await until(() => app.waitingForNetwork);
        await app.next(false);
        await until(() => app.isPlaying);
        expect(app.queue.current!.track.id, upcoming.id);
        expect(
          (app.audio.player.audioSource as UriAudioSource).uri.scheme,
          'file',
        );
        network.set(NetworkKind.unmetered);
        await until(() => !app.offline);
        await app.pause();
        debugPrint(
          'CHECKPOINT: prefetch, network recovery and offline successor passed',
        );
        await app.preloader?.invalidate(downloaded.id);
        await app.playTracks([downloaded, upcoming]);
        network.set(NetworkKind.cellular);
        await until(() => !app.offline);
        await app.setMobileStreaming(false);
        await until(() => app.waitingForNetwork && !app.isPlaying);
        await app.setMobileStreaming(true);
        await until(() => app.isPlaying && !app.waitingForNetwork);
        network.set(NetworkKind.offline);
        await until(() => app.waitingForNetwork && !app.isPlaying);
        await app.pause();
        network.set(NetworkKind.unmetered);
        await tester.pump(const Duration(milliseconds: 600));
        await Future<void>.delayed(const Duration(milliseconds: 400));
        expect(app.isPlaying, false);
        expect(app.wantsPlayback, false);
        debugPrint(
          'CHECKPOINT: mobile policy and explicit pause cancel recovery passed',
        );
      }
      await app.downloads!.add(downloaded);
      await until(() => app.downloads!.contains(downloaded.id), seconds: 180);
      final localPath = app.downloads!.localPath(downloaded.id)!;
      expect(await File(localPath).length(), greaterThan(100));
      expect(
        app.downloads!.groups[downloaded.id]!.folders,
        isNotEmpty,
        reason:
            'Downloading from search preserves ancestry for offline navigation',
      );
      expect(app.isDownloaded(collections.first), true);
      network.set(NetworkKind.offline);
      await until(() => app.offline);
      final group = app.downloads!.groups[downloaded.id]!;
      final parent = group.folders.firstWhere(
        (f) => f.id == group.tracks.first.parentId,
      );
      expect(
        (await app.children(parent)).any((t) => t.id == downloaded.id),
        true,
        reason: 'Offline navigation uses stored folder ancestry',
      );
      final unavailable = all.firstWhere(
        (t) =>
            t.id != downloaded.id &&
            !app.downloads!.contains(t.id) &&
            app.preloader?.localPath(t.id) == null,
      );
      await app.playTracks([unavailable, downloaded]);
      await until(() => app.isPlaying);
      expect(
        app.queue.current!.track.id,
        downloaded.id,
        reason: 'Unavailable offline track is skipped',
      );
      expect(
        (app.audio.player.audioSource as UriAudioSource).uri.scheme,
        'file',
      );
      final shared = DownloadGroup(
        source: const LibraryItem(
          id: 'integration-shared',
          name: 'Temporary local test group',
          kind: ItemKind.playlist,
        ),
        tracks: [downloaded],
      );
      await app.downloads!.apply(shared);
      await app.downloads!.removeGroup(downloaded.id);
      expect(app.downloads!.contains(downloaded.id), true);
      expect(await File(localPath).exists(), true);
      await app.releaseLocalAudio();
      await app.downloads!.removeGroup(shared.source.id);
      expect(app.downloads!.contains(downloaded.id), false);
      expect(await File(localPath).exists(), false);
      network.set(NetworkKind.unmetered);
      await until(() => !app.offline);
      await app.playTracks(tracks, start: 1);
      await app.audio.seek(const Duration(seconds: 8));
      await app.pause();
      await app.save();
      await app.logout();
      await app.login(server, username, password);
      expect(app.isPlaying, false);
      expect(app.queue.current!.track.id, tracks[1].id);
      expect(app.queue.entries.length, tracks.length);
      expect(tester.takeException(), null);
      debugPrint(
        'CHECKPOINT: native download, local playback, shared deletion and restoration passed',
      );
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}

class TestNetwork implements NetworkMonitor {
  final _changes = StreamController<NetworkKind>.broadcast();
  NetworkKind value = NetworkKind.unmetered;
  void set(NetworkKind next) {
    value = next;
    _changes.add(next);
  }

  @override
  Future<NetworkKind> current() async => value;
  @override
  Stream<NetworkKind> get changes => _changes.stream;
}
