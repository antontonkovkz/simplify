import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplefy/infrastructure/jellyfin_library.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simplefy/application/app_controller.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/main.dart' as ui;
import 'package:simplefy/presentation/player_screens.dart';
import 'package:simplefy/presentation/settings_screen.dart';
import 'package:simplefy/presentation/login_screen.dart';
import 'package:simplefy/presentation/widgets.dart';
import 'package:simplefy/presentation/track_count_badge.dart';
import 'local_library_test.dart' show OfflineNetwork, silence;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'local playlist UI saves, loads duplicate occurrence, overwrites and saves as',
    (tester) async {
      final app = await ui.createController(network: OfflineNetwork());
      await app.store.deleteSession();
      await app.store.write('state_local', {});
      await app.store.write('playlists_state_local', {});
      const a = LibraryItem(
        id: 'local:playlist:a',
        parentId: 'local:root',
        name: 'First',
        artist: 'Fixture',
        kind: ItemKind.track,
        fileName: 'A.wav',
        path: 'local_music/playlist/A.wav',
      );
      const b = LibraryItem(
        id: 'local:playlist:b',
        parentId: 'local:root',
        name: 'Second',
        artist: 'Fixture',
        kind: ItemKind.track,
        fileName: 'B.wav',
        path: 'local_music/playlist/B.wav',
      );
      for (final song in [a, b]) {
        final file = File('${app.store.directory.path}/${song.path}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(silence());
      }
      await app.store.write('local_music', {
        'items': [a.toJson(), b.toJson()],
      });
      runApp(ui.SimplefyApp(app: app));
      await app.initialize();
      await app.audio.player.setVolume(0);
      Future<void> until(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (!condition() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 200));
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
        expect(condition(), true);
        await tester.pump(const Duration(milliseconds: 600));
      }

      Future<void> saveAs(String name) async {
        await tester.tap(find.byTooltip('Сохранить очередь'));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.text('Сохранить как…'));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.enterText(
          find.widgetWithText(TextField, 'Название плейлиста'),
          name,
        );
        await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
        await until(() => app.loadedLocalPlaylist?.name == name);
      }

      Future<void> capture(String name) async {
        if (!const bool.fromEnvironment('CAPTURE_BRANDING')) return;
        await tester.pumpAndSettle();
        final bytes = await binding.takeScreenshot(name);
        final file = File(
          '${app.store.directory.path}/brand-previews/$name.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
      }

      Future<void> dismissMenu() async {
        Navigator.of(tester.element(find.text('Проиграть'))).pop();
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
      }

      app.queue.append([a, b, a]);
      app.changed();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.byTooltip('Случайное воспроизведение').first);
      await tester.pump(const Duration(milliseconds: 400));
      expect(app.queue.shuffled, true);
      expect(find.text('Случайно'), findsNothing);
      await tester.tap(find.byTooltip('Случайное воспроизведение').first);
      await tester.pump(const Duration(milliseconds: 400));
      expect(app.queue.shuffled, false);
      expect(find.byTooltip('Предыдущая'), findsOneWidget);
      await tester.pumpAndSettle();
      final localRoot = find.widgetWithText(ItemTile, 'На этом iPhone');
      expect(
        find.descendant(of: localRoot, matching: find.text('2')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
      await tester.longPress(localRoot);
      await tester.pumpAndSettle();
      expect(find.text('Проиграть'), findsOneWidget);
      expect(app.queue.entries, hasLength(3));
      expect(app.queue.current, null);
      await dismissMenu();
      await capture('home');
      if (const bool.fromEnvironment('CAPTURE_BRANDING')) {
        await tester.tap(find.byTooltip('Настройки'));
        await tester.pumpAndSettle();
        await capture('settings');
        await tester.tap(find.text('Подключить Jellyfin'));
        await tester.pumpAndSettle();
        await capture('login');
        Navigator.of(tester.element(find.byType(LoginScreen))).pop();
        await tester.pumpAndSettle();
        Navigator.of(tester.element(find.byType(SettingsScreen))).pop();
        await tester.pumpAndSettle();
      }

      await tester.tap(find.byTooltip('Очередь').first);
      await until(() => find.byType(QueueScreen).evaluate().isNotEmpty);
      await capture('queue');
      final emptyCurrentQueue = tester.state(find.byType(QueueScreen));
      expect(find.byTooltip('Очередь'), findsNothing);
      app.setShuffle(true);
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.text('Случайный выбор включён. Порядок списка сохраняется.'),
        findsNothing,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(MiniPlayer),
          matching: find.text('Очередь · 3'),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(QueueScreen)), same(emptyCurrentQueue));
      app.setShuffle(false);
      await saveAs('Дорога');
      final originalId = app.loadedLocalPlaylistId!;
      expect(app.localPlaylists.tracks(originalId).map((e) => e.id), [
        a.id,
        b.id,
        a.id,
      ]);
      Navigator.of(tester.element(find.byType(QueueScreen))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Плейлисты').last);
      await until(() => find.text('Локальные плейлисты').evaluate().isNotEmpty);
      final playlistRow = find.widgetWithText(ItemTile, 'Дорога');
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: playlistRow, matching: find.text('3')),
        findsOneWidget,
      );
      await tester.longPress(playlistRow);
      await tester.pumpAndSettle();
      expect(find.text('Удалить локальный плейлист'), findsOneWidget);
      await dismissMenu();
      await tester.tap(playlistRow);
      await tester.pumpAndSettle();
      await until(() => find.text('First').evaluate().length >= 2);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
      expect(
        find.descendant(
          of: find.byType(TrackCountBadge),
          matching: find.text('3'),
        ),
        findsOneWidget,
      );
      await tester.longPress(find.text('Дорога'));
      await tester.pumpAndSettle();
      expect(find.text('Добавить в очередь'), findsOneWidget);
      await dismissMenu();
      await tester.longPress(find.text('First').first);
      await tester.pumpAndSettle();
      expect(app.queue.current, null);
      expect(find.text('Проиграть'), findsOneWidget);
      await dismissMenu();
      // Selecting the second occurrence must start at index 2, not index 0.
      await tester.tap(find.text('First').last);
      await until(() => app.isPlaying);
      expect(app.queue.entries.indexOf(app.queue.current!), 2);
      expect(app.loadedLocalPlaylistId, originalId);
      await app.pause();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Очередь').first);
      await until(() => find.byType(QueueScreen).evaluate().isNotEmpty);
      final originalQueue = tester.state(find.byType(QueueScreen));
      expect(find.byTooltip('Очередь'), findsNothing);
      // Opening the full player from the queue must return to this same queue.
      for (var i = 0; i < 2; i++) {
        await tester.tap(
          find.descendant(
            of: find.byType(MiniPlayer),
            matching: find.text('First'),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(PlayerScreen), findsOneWidget);
        expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);
        if (i == 0) {
          await tester.longPress(find.text('First'));
          await tester.pumpAndSettle();
          expect(find.text('Проиграть'), findsOneWidget);
          await dismissMenu();
          expect(app.queue.entries, hasLength(3));
        }

        if (i == 0) await capture('player');
        await tester.tap(find.widgetWithText(OutlinedButton, 'Очередь · 3'));
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(QueueScreen)), same(originalQueue));
        expect(find.byType(QueueScreen, skipOffstage: false), findsOneWidget);
        expect(find.byType(PlayerScreen, skipOffstage: false), findsNothing);
      }
      app.move(0, 2);
      await app.remove(app.queue.entries.last.id);
      expect(app.localPlaylists.tracks(originalId), hasLength(3));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.byTooltip('Сохранить очередь'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Сохранить в «Дорога»'));
      await until(() => app.localPlaylists.tracks(originalId).length == 2);
      expect(app.localPlaylists.tracks(originalId).map((e) => e.id), [
        b.id,
        a.id,
      ]);
      await saveAs('Новая дорога');
      final copiedId = app.loadedLocalPlaylistId!;
      expect(copiedId, isNot(originalId));
      expect(app.localPlaylists.items, hasLength(2));
      await app.save();
      final audio = app.audio;
      final store = app.store;
      runApp(const SizedBox.shrink());
      await tester.pump();
      app.dispose();
      final restored = AppController(store, audio, network: OfflineNetwork());
      runApp(ui.SimplefyApp(app: restored));
      await restored.initialize();
      expect(restored.loadedLocalPlaylistId, copiedId);
      expect(restored.localPlaylists.items, hasLength(2));
      expect(restored.queue.entries.map((e) => e.track.id), [b.id, a.id]);
      expect(restored.isPlaying, false);
      await restored.deleteLocalPlaylist(
        restored.localPlaylists.item(copiedId)!,
      );
      expect(restored.loadedLocalPlaylistId, null);
      expect(restored.queue.entries, hasLength(2));
      expect(await File('${store.directory.path}/${a.path}').exists(), true);
      expect(tester.takeException(), null);
      restored.queue.append([b]);
      restored.changed();
      await restored.playTracks([a]);
      await restored.pause();
      expect(restored.loadedLocalPlaylistId, null);
      await restored.stop();
      // Server provenance survives local-copy saving and restoration. This
      // fixture never sends a request to a real Jellyfin server.
      const remote = LibraryItem(
        id: 'remote-playlist',
        name: '_test',
        kind: ItemKind.playlist,
      );
      final api = JellyfinLibrary(
        const ServerSession('https://example.com', 'u', 'fake', 'u'),
        client: MockClient(
          (request) async => http.Response(jsonEncode({'CanEdit': true}), 200),
        ),
      );
      restored.library = api;
      await restored.playTracks([a, b], serverPlaylistSource: remote);
      await restored.pause();
      await restored.serverPlaylist.refreshAccess(api);
      expect(restored.serverPlaylist.item?.id, remote.id);
      expect(restored.loadedLocalPlaylistId, null);
      await tester.pumpAndSettle();
      Navigator.of(
        tester.element(find.byType(Scaffold).first),
      ).push(slideRoute(QueueScreen(app: restored)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Сохранить очередь'));
      await tester.pumpAndSettle();
      expect(find.text('Как локальный плейлист…'), findsOneWidget);
      expect(find.text('Сохранить удалённый плейлист'), findsOneWidget);
      final serverAction = tester.widget<PopupMenuItem<String>>(
        find.ancestor(
          of: find.text('Сохранить удалённый плейлист'),
          matching: find.byType(PopupMenuItem<String>),
        ),
      );
      expect(
        serverAction.enabled,
        false,
        reason: 'Offline server saving must be disabled',
      );
      await tester.tap(find.text('Как локальный плейлист…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Название плейлиста'),
        'Копия серверного',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Сохранить'));
      await until(
        () => restored.localPlaylists.items.any(
          (item) => item.name == 'Копия серверного',
        ),
      );
      expect(restored.serverPlaylist.item?.id, remote.id);
      expect(restored.loadedLocalPlaylistId, null);
      await restored.save();
      final persisted = await store.read('state_local');
      expect(persisted['serverPlaylist']['item']['id'], remote.id);
      await restored.playTracks([a]);
      await restored.pause();
      expect(restored.serverPlaylist.item, null);
      await restored.stop();
      debugPrint('SIMPLEFY_LOCAL_PLAYLISTS_PASSED');
    },
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
