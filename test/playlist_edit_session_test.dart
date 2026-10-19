import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/application/playlist_edit_session.dart';
import 'package:simplefy/application/ports.dart';
import 'package:simplefy/application/server_playlist_editor.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/domain/playlist_draft.dart';

const a = LibraryItem(id: 'a', name: 'A', kind: ItemKind.track);
const b = LibraryItem(id: 'b', name: 'B', kind: ItemKind.track);
const source = LibraryItem(id: 'p', name: 'Playlist', kind: ItemKind.playlist);

class FakeServer implements ServerPlaylists {
  List<String> ids = ['a', 'b', 'a'];
  bool allowed = true;
  int writes = 0;
  Completer<void>? gate;
  @override
  Future<bool> canEditPlaylist(String id) async => allowed;
  @override
  Future<void> validatePlaylistTracks(List<String> ids) async {
    await gate?.future;
  }

  @override
  Future<List<String>> playlistIds(String id) async => List.of(ids);
  @override
  Future<void> replacePlaylist(String id, List<String> items) async {
    writes++;
    ids = List.of(items);
  }
}

void main() {
  test('draft preserves duplicate occurrences and can undo a reorder', () {
    final draft = PlaylistDraft([a, b, a]);
    final snapshot = draft.entries;
    expect(snapshot.map((e) => e.id).toSet(), hasLength(3));
    draft.move(0, 2);
    expect(draft.tracks.map((e) => e.id), ['b', 'a', 'a']);
    expect(draft.hasChanges, true);
    draft.move(1, 0);
    expect(draft.hasChanges, false);
    draft.remove(draft.entries.last.id);
    expect(draft.tracks.map((e) => e.id), ['a', 'b']);
    expect(snapshot, hasLength(3));
    expect(() => snapshot.clear(), throwsUnsupportedError);
    draft.append([a]);
    expect(draft.hasChanges, false);
  });

  late ChangeNotifier environment;
  late FakeServer server;
  late PlaylistEditSession session;
  bool current = true;
  bool offline = false;
  List<LibraryItem>? savedLocal;
  int refreshed = 0;
  setUp(() {
    environment = ChangeNotifier();
    server = FakeServer();
    current = true;
    offline = false;
    savedLocal = null;
    refreshed = 0;
    session = PlaylistEditSession(
      source: source,
      loadTracks: () async => [a, b, a],
      server: server,
      environment: environment,
      isCurrent: () => current,
      isOffline: () => offline,
      saveLocal: (tracks, name) async {
        savedLocal = List.of(tracks);
        return LibraryItem(
          id: 'local-playlist:copy',
          name: name,
          kind: ItemKind.playlist,
        );
      },
      serverSaved: () async {
        refreshed++;
      },
    );
  });
  tearDown(() {
    session.dispose();
    environment.dispose();
  });

  test(
    'local export preserves remote baseline and explicit conflict handling',
    () async {
      await session.initialize();
      session.move(0, 2);
      await session.saveAsLocal('Copy');
      expect(savedLocal!.map((e) => e.id), ['b', 'a', 'a']);
      expect(server.writes, 0);
      expect(session.draft!.hasChanges, false);
      server.ids = ['b'];
      await expectLater(
        session.saveToServer(),
        throwsA(isA<ServerPlaylistConflict>()),
      );
      expect(server.writes, 0);
      await session.saveToServer(overwriteChanged: true);
      expect(server.ids, ['b', 'a', 'a']);
      expect(refreshed, 1);
      session.append([b]);
      await session.saveToServer();
      expect(server.ids, ['b', 'a', 'a', 'b']);
    },
  );

  test(
    'permissions are rechecked; read-only and offline drafts export locally',
    () async {
      await session.initialize();
      server.allowed = false;
      session.remove(session.draft!.entries.first.id);
      await expectLater(session.saveToServer(), throwsA(isA<AppFailure>()));
      expect(server.writes, 0);
      expect(session.canSaveServer, false);
      offline = true;
      await session.saveAsLocal('Offline copy');
      expect(savedLocal!.map((e) => e.id), ['b', 'a']);
      await expectLater(session.saveToServer(), throwsA(isA<AppFailure>()));
    },
  );

  test(
    'saving freezes edits and account switch cancels preflight write',
    () async {
      await session.initialize();
      server.gate = Completer<void>();
      final save = session.saveToServer();
      final failed = expectLater(save, throwsA(isA<AppFailure>()));
      expect(session.busy, true);
      expect(() => session.append([b]), throwsA(isA<AppFailure>()));
      current = false;
      environment.notifyListeners();
      expect(session.expired, true);
      server.gate!.complete();
      await failed;
      expect(server.writes, 0);
      expect(session.busy, false);
    },
  );

  test(
    'empty draft can be saved locally and explicitly cleared remotely',
    () async {
      await session.initialize();
      for (final entry in session.draft!.entries) {
        session.remove(entry.id);
      }
      await session.saveAsLocal('Empty');
      expect(savedLocal, isEmpty);
      await session.saveToServer();
      expect(server.ids, isEmpty);
      expect(session.draft!.hasChanges, false);
    },
  );
}
