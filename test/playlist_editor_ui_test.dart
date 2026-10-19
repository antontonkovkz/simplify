import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/application/playlist_edit_session.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/presentation/app_theme.dart';
import 'package:simplefy/presentation/editable_track_row.dart';
import 'package:simplefy/presentation/playlist_editor_screen.dart';
import 'package:simplefy/presentation/widgets.dart';
import 'compact_ui_test.dart' show TestApp, songs, folder;
import 'playlist_edit_session_test.dart' show FakeServer, source;

class EditorApp extends TestApp {
  late PlaylistEditSession editor;
  final api = FakeServer();
  List<LibraryItem>? localCopy;
  @override
  PlaylistEditSession editServerPlaylist(LibraryItem source) =>
      editor = PlaylistEditSession(
        source: source,
        loadTracks: () async => [songs[0], songs[1], songs[0]],
        server: api..ids = [songs[0].id, songs[1].id, songs[0].id],
        saveLocal: (tracks, name) async {
          localCopy = List.of(tracks);
          return LibraryItem(
            id: 'local-playlist:copy',
            name: name,
            kind: ItemKind.playlist,
          );
        },
        serverSaved: () async {},
        environment: this,
        isCurrent: () => true,
        isOffline: () => false,
      );
  @override
  Future<List<LibraryItem>> root(bool playlists) async =>
      playlists ? [] : [folder];
  @override
  Future<List<LibraryItem>> tracks(
    LibraryItem item, {
    bool recursive = true,
  }) async => songs;
  @override
  void message(String text) {}
}

void main() {
  late EditorApp app;
  setUp(() {
    app = EditorApp();
  });
  tearDown(() {
    app.dispose();
  });
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SimplefyTheme.dark,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                slideRoute(PlaylistEditorScreen(app: app, source: source)),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'nested chooser appends songs, server save leaves queue untouched',
    (tester) async {
      app.queue.replace(songs);
      final queue = app.queue.entries;
      await open(tester);
      await tester.tap(find.byTooltip('Добавить композиции'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(folder.name));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Добавить · 1'));
      await tester.pumpAndSettle();
      expect(find.byType(EditableTrackRow), findsNWidgets(4));
      expect(app.editor.draft!.tracks.last.id, songs.last.id);
      final row = find.byType(EditableTrackRow).first;
      await tester.drag(row, const Offset(-650, 0));
      await tester.pumpAndSettle();
      expect(app.editor.draft!.tracks.map((t) => t.id), [
        songs[1].id,
        songs[0].id,
        songs[2].id,
      ]);
      await tester.tap(find.byTooltip('Сохранить плейлист'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сохранить удалённый плейлист'));
      await tester.pumpAndSettle();
      expect(app.api.ids, [songs[1].id, songs[0].id, songs[2].id]);
      expect(app.api.writes, 1);
      expect(identical(app.queue.entries, queue), true);
      expect(app.serverPlaylist.item, null);
      expect(find.text('Сохранено на сервере'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'read-only source exports draft locally; dirty exit asks before discarding',
    (tester) async {
      app.api.allowed = false;
      await open(tester);
      app.editor.move(0, 2);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Выйти без сохранения?'), findsOneWidget);
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Сохранить плейлист'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuItem<String>>(
              find.widgetWithText(
                PopupMenuItem<String>,
                'Сохранить удалённый плейлист',
              ),
            )
            .enabled,
        false,
      );
      await tester.tap(find.text('Как локальный плейлист…'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'My copy');
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(app.localCopy!.map((t) => t.id), [
        songs[1].id,
        songs[0].id,
        songs[0].id,
      ]);
      expect(app.api.writes, 0);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Open'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
