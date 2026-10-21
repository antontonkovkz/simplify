import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simplefy/main.dart' as ui;
import 'package:simplefy/presentation/library_screens.dart';
import 'package:simplefy/presentation/player_screens.dart';
import 'package:simplefy/presentation/widgets.dart';
import 'package:simplefy/infrastructure/local_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized()
      .platformDispatcher
      .localeTestValue = const Locale(
    'ru',
  );
  testWidgets(
    'folder context actions, both search choices, pending queue and drag reorder',
    (tester) async {
      const session = String.fromEnvironment('CATALOG_TEST_SESSION');
      if (session.isNotEmpty) {
        await (await LocalStore.open()).saveSession(session);
      }
      await ui.main();
      Future<void> until(bool Function() ready, {int seconds = 60}) async {
        final end = DateTime.now().add(Duration(seconds: seconds));
        while (DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 200));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          if (ready()) {
            await tester.pump(const Duration(milliseconds: 350));
            if (ready()) return;
          }
        }
        expect(
          ready(),
          true,
          reason: 'Catalog integration checkpoint timed out',
        );
      }

      await until(() => find.byType(ui.SimplefyApp).evaluate().isNotEmpty);
      final app = tester
          .widget<ui.SimplefyApp>(find.byType(ui.SimplefyApp))
          .app;
      await until(() => app.initialized);
      expect(
        app.loggedIn,
        true,
        reason: 'Run the main integration scenario first',
      );
      await app.audio.player.setVolume(0);
      final root = (await app.root(false)).first;
      await until(() => find.text(root.name).evaluate().isNotEmpty);
      await tester.tap(find.text(root.name).first);
      await until(() => find.byType(LibraryScreen).evaluate().isNotEmpty);
      await tester.timedDragFrom(
        const Offset(1, 300),
        const Offset(350, 0),
        const Duration(milliseconds: 350),
      );
      await until(() => find.byType(LibraryScreen).evaluate().isEmpty);
      await tester.tap(find.text(root.name).first);
      await until(() => find.byType(LibraryScreen).evaluate().isNotEmpty);
      final folders = (await app.children(
        root,
      )).where((e) => !e.isTrack).toList();
      final folder = folders.first;
      final contents = await app.tracks(folder);
      final tile = find.widgetWithText(ItemTile, folder.name);
      await until(() => tile.evaluate().isNotEmpty);
      await tester.longPress(tile);
      await until(() => find.text('Проиграть').evaluate().isNotEmpty);
      await tester.tap(find.text('Проиграть'));
      await until(
        () => app.isPlaying && app.queue.entries.length == contents.length,
      );
      expect(
        app.queue.entries.map((e) => e.track.id),
        contents.map((e) => e.id),
      );
      final playing = app.queue.current!.id;
      final playlist = (await app.root(true)).first;
      final playlistTracks = await app.tracks(playlist);
      await app.addGroup(playlist);
      expect(app.queue.current!.id, playing);
      expect(app.isPlaying, true);
      expect(app.queue.entries.length, contents.length + playlistTracks.length);

      await tester.tap(find.byTooltip('Поиск').first);
      await until(() => find.byType(SearchScreen).evaluate().isNotEmpty);
      final selected = contents.first;
      await tester.enterText(find.byType(TextField).first, selected.fileName);
      final found = find.widgetWithText(ItemTile, selected.filenameTitle);
      await until(() => found.evaluate().isNotEmpty);
      await tester.tap(found);
      await until(() => find.text('Где продолжить?').evaluate().isNotEmpty);
      await tester.tap(find.text('Отмена'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(app.queue.current!.id, playing);
      await tester.tap(found);
      await until(
        () => find.text('В папке этой композиции').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('В папке этой композиции'));
      await until(
        () => app.isPlaying && app.queue.current?.track.id == selected.id,
      );
      expect(
        app.queue.entries.every(
          (e) => e.track.parentId == app.queue.current!.track.parentId,
        ),
        true,
      );
      final containing = app.queue.entries.map((e) => e.track).toList();
      await tester.tap(found);
      await until(
        () => find.text('В результатах поиска').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('В результатах поиска'));
      final results = await app.search(root, selected.fileName);
      await until(
        () => app.isPlaying && app.queue.entries.length == results.length,
      );
      expect(app.queue.current!.track.id, selected.id);

      await app.pause();
      app.queue.replace([]);
      app.queue.append(
        containing.length >= 3
            ? containing.take(3).toList()
            : playlistTracks.take(3).toList(),
      );
      app.changed();
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 400));
      await until(() => find.byTooltip('Очередь').evaluate().isNotEmpty);
      await tester.tap(find.byTooltip('Очередь').first);
      await until(() => find.byType(QueueScreen).evaluate().isNotEmpty);
      final third = app.queue.entries[2].id;
      final handles = find.byIcon(Icons.drag_handle_rounded);
      await until(() => handles.evaluate().length == 3);
      final from = tester.getCenter(handles.at(2));
      final to = tester.getCenter(handles.first) - const Offset(0, 20);
      await tester.timedDragFrom(from, to - from, const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 600));
      await until(() => app.queue.entries.first.id == third);
      expect(app.queue.entries.length, 3);
      await tester.timedDragFrom(
        const Offset(1, 300),
        const Offset(350, 0),
        const Duration(milliseconds: 350),
      );
      await until(() => find.byType(QueueScreen).evaluate().isEmpty);
      expect(app.queue.entries.first.id, third);
      expect(tester.takeException(), null);
      await app.save();
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
