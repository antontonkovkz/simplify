import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:simplefy/application/app_controller.dart';
import 'package:simplefy/domain/download_group.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/infrastructure/download_manager.dart';
import 'package:simplefy/infrastructure/jellyfin_library.dart';
import 'package:simplefy/infrastructure/local_store.dart';
import 'package:simplefy/presentation/app_theme.dart';
import 'package:simplefy/presentation/downloaded_tracks_screen.dart';
import '../test/downloaded_tracks_ui_test.dart' as scenarios;
import '../test/playlist_edit_controller_test.dart' show IdleAudio;

class _ReadyApp extends AppController {
  _ReadyApp(super.store, super.audio);
  @override
  bool get loggedIn => true;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  scenarios.main();
  testWidgets(
    'real download index deduplicates files, removes shared copies and persists deletion',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'simplefy-files-',
      );
      final store = LocalStore(directory);
      final api = JellyfinLibrary(
        const ServerSession(
          'https://example.com',
          'fixture',
          'fixture',
          'fixture',
        ),
      );
      final manager = DownloadManager(store, api);
      final app = _ReadyApp(store, IdleAudio())
        ..library = api
        ..downloads = manager;
      const a = LibraryItem(
        id: 'a',
        name: 'Alpha',
        artist: 'Fixture',
        kind: ItemKind.track,
      );
      const b = LibraryItem(
        id: 'b',
        name: 'Beta',
        artist: 'Fixture',
        kind: ItemKind.track,
      );
      const pending = LibraryItem(
        id: 'pending',
        name: 'Pending',
        kind: ItemKind.track,
      );
      const folder = LibraryItem(
        id: 'folder',
        name: 'Folder',
        kind: ItemKind.folder,
      );
      const playlist = LibraryItem(
        id: 'playlist',
        name: 'Playlist',
        kind: ItemKind.playlist,
      );
      final files = {'a': 'a.flac', 'b': 'b.flac', 'orphan': 'orphan.flac'};
      File file(String name) =>
          File('${directory.path}/music/${manager.namespace}/$name');
      for (final name in files.values) {
        await file(name).parent.create(recursive: true);
        await file(name).writeAsString('Fixture file, never played');
      }
      await store.write('downloads_${manager.namespace}', {
        'files': files,
        'groups': [
          const DownloadGroup(source: folder, tracks: [a, b, a]).toJson(),
          const DownloadGroup(
            source: playlist,
            tracks: [a, b, pending],
          ).toJson(),
          const DownloadGroup(source: a, tracks: [a]).toJson(),
        ],
      });
      try {
        await manager.initialize();
        expect(manager.completedTracks.map((t) => t.id), ['a', 'b', 'orphan']);
        final snapshot = manager.completedTracks;
        manager.progress['pending'] = .5;
        expect(manager.completedTracks, same(snapshot));
        expect(() => snapshot.clear(), throwsUnsupportedError);
        app.queue.replace([b, a]);
        final queue = app.queue.entries;
        await tester.pumpWidget(
          MaterialApp(
            theme: SimplefyTheme.dark,
            home: DownloadedTracksScreen(app: app),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Удалить с устройства').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Удалить'));
        await tester.pumpAndSettle();
        expect(manager.contains('a'), false);
        expect(await file('a.flac').exists(), false);
        expect(await file('b.flac').exists(), true);
        expect(manager.groups.containsKey('a'), false);
        expect(
          manager.groups.values.expand((g) => g.tracks).any((t) => t.id == 'a'),
          false,
        );
        expect(manager.groups['playlist']!.tracks.map((t) => t.id), [
          'b',
          'pending',
        ]);
        expect(app.queue.entries, same(queue));
        expect(snapshot, hasLength(3));
        expect(manager.completedTracks, hasLength(2));
        await manager.removeTrack('orphan');
        expect(await file('orphan.flac').exists(), false);
        await tester.pumpWidget(const SizedBox());
        final reopened = DownloadManager(store, api);
        try {
          await reopened.initialize();
          expect(reopened.completedTracks.map((t) => t.id), ['b']);
          expect(reopened.completedCount, 1);
        } finally {
          reopened.dispose();
        }
      } finally {
        await tester.pumpWidget(const SizedBox());
        app.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
