import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/application/app_controller.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/infrastructure/download_manager.dart';
import 'package:simplefy/infrastructure/jellyfin_library.dart';
import 'package:simplefy/infrastructure/local_store.dart';
import 'package:simplefy/infrastructure/music_audio_handler.dart';
import 'playlist_edit_session_test.dart' show a, b, source;

class IdleAudio implements MusicAudioHandler {
  @override
  void cancelGainAdjustment() {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Editor touched audio: ${invocation.memberName}');
}

class ScopedDownloads implements DownloadManager {
  @override
  String get namespace => 'fixture';
  @override
  void dispose() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MemoryLibrary extends JellyfinLibrary {
  MemoryLibrary()
    : super(
        const ServerSession(
          'https://example.com',
          'fixture',
          'fixture',
          'fixture',
        ),
      );
  List<LibraryItem> contents = [a, b, a];
  @override
  Future<List<LibraryItem>> children(LibraryItem parent) async =>
      List.of(contents);
  @override
  Future<bool> canEditPlaylist(String id) async => true;
  @override
  Future<List<String>> playlistIds(String id) async =>
      contents.map((t) => t.id).toList();
  @override
  Future<void> validatePlaylistTracks(List<String> ids) async {}
  @override
  Future<void> replacePlaylist(String id, List<String> ids) async {
    contents = ids.map((id) => id == a.id ? a : b).toList();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'controller refreshes catalog and persists local copies without touching playback provenance',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'simplefy-editor-',
      );
      final store = LocalStore(directory);
      final app = AppController(store, IdleAudio());
      final library = MemoryLibrary();
      app.library = library;
      app.downloads = ScopedDownloads();
      await app.localPlaylists.load('fixture');
      app.queue.replace([b, a]);
      await app.serverPlaylist.open(library, source, baseline: ['a', 'b', 'a']);
      final queue = app.queue.entries;
      final editor = app.editServerPlaylist(source);
      try {
        await editor.initialize();
        editor.remove(editor.draft!.entries.first.id);
        await editor.saveToServer();
        expect((await app.children(source)).map((t) => t.id), ['b', 'a']);
        expect(app.serverPlaylistRevision, 1);
        expect(app.queue.entries, same(queue));
        expect(app.serverPlaylist.hasChanges(['b', 'a']), true);
        expect(app.serverPlaylist.item?.id, source.id);
        final copy = await editor.saveAsLocal('Copy');
        expect(app.localPlaylists.tracks(copy.id).map((t) => t.id), ['b', 'a']);
        expect(app.localRevision, 1);
        expect(app.loadedLocalPlaylistId, null);
        expect(app.queue.entries, same(queue));
        // Let asynchronous catalog writes finish before removing their directory.
        await store.read('catalog_fixture');
      } finally {
        editor.dispose();
        app.dispose();
        await directory.delete(recursive: true);
      }
    },
  );
}
