import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplefy/application/app_controller.dart';
import 'package:simplefy/application/playlist_mutations.dart';
import 'package:simplefy/application/ports.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/infrastructure/jellyfin_library.dart';
import 'package:simplefy/infrastructure/local_store.dart';
import 'playlist_edit_controller_test.dart' show IdleAudio, ScopedDownloads;

const p1 = LibraryItem(id: 'p1', name: 'One', kind: ItemKind.playlist);
const p2 = LibraryItem(id: 'p2', name: 'Two', kind: ItemKind.playlist);
const a = LibraryItem(id: 'a', name: 'A', kind: ItemKind.track);
const b = LibraryItem(id: 'b', name: 'B', kind: ItemKind.track);
const local = LibraryItem(id: 'local:a', name: 'Local', kind: ItemKind.track);

class PlaylistServer {
  final contents = <String, List<String>>{
    'p1': ['a'],
    'p2': ['b'],
  };
  List<String>? staleListing;
  final writes = <String>[];
  Map<String, dynamic>? payload;
  int createStatus = 200;
  int deleteStatus = 204;
  int preflightStatus = 200;
  bool wrongType = false;
  bool allowed = true;
  bool missingAudio = false;
  bool badContents = false;
  bool verificationFails = false;
  bool connectionFails = false;
  Completer<void>? validationWait;
  Completer<void>? deletionWait;
  void Function()? afterCreate;
  late final api = JellyfinLibrary(
    const ServerSession('https://example.com', 'user', 'fixture', 'fixture'),
    client: MockClient((request) async {
      final path = request.url.path;
      if (path == '/Items' && request.method == 'GET') {
        if (request.url.queryParameters['IncludeItemTypes'] == 'Playlist') {
          return http.Response(
            jsonEncode({
              'Items': (staleListing ?? contents.keys)
                  .map((id) => {'Id': id, 'Name': id, 'Type': 'Playlist'})
                  .toList(),
              'TotalRecordCount': contents.length,
            }),
            200,
          );
        }
        await validationWait?.future;
        return http.Response(
          jsonEncode({
            'Items': missingAudio
                ? []
                : request.url.queryParameters['Ids']!
                      .split(',')
                      .map((id) => {'Id': id, 'Type': 'Audio'})
                      .toList(),
          }),
          200,
        );
      }
      if (path == '/Playlists' && request.method == 'POST') {
        writes.add('create');
        payload = jsonDecode(request.body) as Map<String, dynamic>;
        if (connectionFails) {
          throw http.ClientException('fixture connection failure');
        }
        if (createStatus == 200) {
          contents['new'] = badContents
              ? []
              : (payload!['Ids'] as List).cast<String>();
        }
        afterCreate?.call();
        return http.Response(jsonEncode({'Id': 'new'}), createStatus);
      }
      if (path.startsWith('/Playlists/') && path.endsWith('/Users/user')) {
        return http.Response(jsonEncode({'CanEdit': true}), 200);
      }
      if (path.startsWith('/Playlists/') && request.method == 'GET') {
        if (verificationFails && path.endsWith('/new')) {
          return http.Response('', 500);
        }
        return http.Response(
          jsonEncode({'ItemIds': contents[path.split('/').last]}),
          200,
        );
      }
      if (path.startsWith('/Items/') && request.method == 'GET') {
        await deletionWait?.future;
        if (preflightStatus != 200) return http.Response('', preflightStatus);
        final id = path.split('/').last;
        if (!contents.containsKey(id)) return http.Response('', 404);
        return http.Response(
          jsonEncode({
            'Id': id,
            'Name': id,
            'Type': wrongType ? 'Audio' : 'Playlist',
            'CanDelete': allowed,
          }),
          200,
        );
      }
      if (path.startsWith('/Items/') && request.method == 'DELETE') {
        final id = path.split('/').last;
        writes.add('delete:$id');
        if (deleteStatus == 204) contents.remove(id);
        return http.Response('', deleteStatus);
      }
      fail('Unexpected request: ${request.method} $path');
    }),
  );
}

class ReadyPlaylistApp extends AppController {
  ReadyPlaylistApp(LocalStore store) : super(store, IdleAudio());
  @override
  bool get loggedIn => library != null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PlaylistServer server;
  setUp(() => server = PlaylistServer());
  tearDown(() => server.api.close());

  test(
    'creation uses a private Audio playlist and preserves order and repeated occurrences',
    () async {
      final item = await PlaylistMutations().create(server.api, '  Copy  ', [
        b,
        a,
        b,
      ], isCurrent: () => true);
      expect(item.name, 'Copy');
      expect(server.payload, {
        'Name': 'Copy',
        'Ids': ['b', 'a', 'b'],
        'UserId': 'user',
        'MediaType': 'Audio',
        'IsPublic': false,
      });
      expect(server.writes, ['create']);
    },
  );

  test(
    'invalid names, empty queues, local files and unavailable audio never create a server playlist',
    () async {
      final mutation = PlaylistMutations();
      for (final entry in [
        ('', [a]),
        ('Copy', <LibraryItem>[]),
        ('Copy', [a, local]),
      ]) {
        await expectLater(
          mutation.create(
            server.api,
            entry.$1,
            entry.$2,
            isCurrent: () => true,
          ),
          throwsA(isA<AppFailure>()),
        );
      }
      server.missingAudio = true;
      await expectLater(
        mutation.create(server.api, 'Copy', [a], isCurrent: () => true),
        throwsA(isA<AppFailure>()),
      );
      expect(server.writes, isEmpty);
    },
  );

  test(
    'account switch during preflight cancels creation and deletion before the write',
    () async {
      var current = true;
      server.validationWait = Completer<void>();
      final mutation = PlaylistMutations();
      final create = mutation.create(server.api, 'Copy', [
        a,
      ], isCurrent: () => current);
      final createCheck = expectLater(create, throwsA(isA<AppFailure>()));
      await Future<void>.delayed(Duration.zero);
      current = false;
      server.validationWait!.complete();
      await createCheck;
      current = true;
      server.deletionWait = Completer<void>();
      final deletion = server.api.deletePlaylist(p1, isCurrent: () => current);
      final deletionCheck = expectLater(deletion, throwsA(isA<AppFailure>()));
      await Future<void>.delayed(Duration.zero);
      current = false;
      server.deletionWait!.complete();
      await deletionCheck;
      expect(server.writes, isEmpty);
    },
  );

  test(
    'confirmed creation with unverifiable contents exposes its ID and never retries POST',
    () async {
      server.verificationFails = true;
      await expectLater(
        PlaylistMutations().create(server.api, 'Copy', [
          a,
        ], isCurrent: () => true),
        throwsA(
          isA<CreatedPlaylistUnverified>().having(
            (e) => e.item.id,
            'created ID',
            'new',
          ),
        ),
      );
      expect(server.writes, ['create']);
      expect(server.contents['new'], ['a']);
    },
  );

  test(
    'forbidden and ambiguous creation produce one POST and no automatic retry',
    () async {
      for (final status in [401, 403, 500]) {
        server.createStatus = status;
        await expectLater(
          PlaylistMutations().create(server.api, 'Copy', [
            a,
          ], isCurrent: () => true),
          throwsA(isA<AppFailure>()),
        );
      }
      server.connectionFails = true;
      await expectLater(
        PlaylistMutations().create(server.api, 'Copy', [
          a,
        ], isCurrent: () => true),
        throwsA(isA<AppFailure>()),
      );
      expect(server.writes, List.filled(4, 'create'));
    },
  );

  test(
    'delete rejects tracks, folders, local IDs and mismatched server types without DELETE',
    () async {
      for (final item in [
        a,
        local,
        const LibraryItem(id: 'p1', name: 'Folder', kind: ItemKind.folder),
      ]) {
        await expectLater(
          server.api.deletePlaylist(item, isCurrent: () => true),
          throwsA(isA<AppFailure>()),
        );
      }
      server.wrongType = true;
      await expectLater(
        server.api.deletePlaylist(p1, isCurrent: () => true),
        throwsA(isA<AppFailure>()),
      );
      server.wrongType = false;
      server.allowed = false;
      await expectLater(
        server.api.deletePlaylist(p1, isCurrent: () => true),
        throwsA(isA<AppFailure>()),
      );
      server.allowed = true;
      server.preflightStatus = 403;
      await expectLater(
        server.api.deletePlaylist(p1, isCurrent: () => true),
        throwsA(isA<AppFailure>().having((e) => e.status, 'status', 403)),
      );
      expect(server.writes, isEmpty);
    },
  );

  test(
    'delete converges for missing playlists and reports server denial instead of treating it as success',
    () async {
      for (final status in [401, 403, 500]) {
        server.deleteStatus = status;
        await expectLater(
          server.api.deletePlaylist(p1, isCurrent: () => true),
          throwsA(isA<AppFailure>()),
        );
      }
      server.deleteStatus = 204;
      await server.api.deletePlaylist(p1, isCurrent: () => true);
      await server.api.deletePlaylist(p1, isCurrent: () => true);
      expect(server.writes, List.filled(4, 'delete:p1'));
      expect(server.contents.keys, ['p2']);
    },
  );

  test(
    'batch retains failed selections, removes successful rows and prevents concurrent deletion',
    () async {
      final gate = Completer<void>();
      final removed = <String>[];
      var failSecond = true;
      final selection = PlaylistDeletion(
        initial: p1,
        isCurrent: () => true,
        remove: (item) async {
          await gate.future;
          if (item.id == 'p2' && failSecond) throw const AppFailure('Denied');
          removed.add(item.id);
        },
      );
      selection.toggle(p2);
      final deleting = selection.deleteSelected();
      selection.toggle(p1);
      await selection.deleteSelected();
      gate.complete();
      await deleting;
      expect(removed, ['p1']);
      expect(selection.selected.keys, ['p2']);
      expect(selection.deleted, {'p1'});
      expect(selection.errors.keys, ['p2']);
      failSecond = false;
      await selection.deleteSelected();
      expect(selection.selected, isEmpty);
      expect(selection.errors, isEmpty);
      expect(removed, ['p1', 'p2']);
      selection.dispose();
    },
  );

  test(
    'batch stops remaining writes when the account changes during a request',
    () async {
      var current = true;
      final removed = <String>[];
      final selection = PlaylistDeletion(
        initial: p1,
        isCurrent: () => current,
        remove: (item) async {
          removed.add(item.id);
          current = false;
        },
      );
      selection.toggle(p2);
      await selection.deleteSelected();
      expect(removed, ['p1']);
      expect(selection.selected.keys, ['p2']);
      selection.dispose();
    },
  );

  for (final scenario in [(false, false), (true, false), (false, true)]) {
    final editDuringRequest = scenario.$1;
    final verificationFails = scenario.$2;
    test(
      'controller creates, caches, deletes and preserves playback (concurrent queue edit=$editDuringRequest, verify failure=$verificationFails)',
      () async {
        server.verificationFails = verificationFails;
        final directory = await Directory.systemTemp.createTemp(
          'simplefy-playlists-',
        );
        final store = LocalStore(directory);
        final app = ReadyPlaylistApp(store)
          ..library = server.api
          ..downloads = ScopedDownloads();
        await app.localPlaylists.load('fixture');
        app.queue.replace([b, a, b]);
        await app.root(true);
        if (editDuringRequest) server.afterCreate = () => app.queue.append([a]);
        try {
          app.serverPlaylist.saving = true;
          await expectLater(
            app.createServerPlaylistFromQueue('Copy'),
            throwsA(isA<AppFailure>()),
          );
          app.serverPlaylist.saving = false;
          await app.createServerPlaylistFromQueue('Copy');
          final queue = app.queue.entries;
          expect(app.peekRoot(true)!.any((p) => p.id == 'new'), true);
          expect(
            app.serverPlaylist.item?.id,
            editDuringRequest || verificationFails ? null : 'new',
          );
          expect(server.contents['new'], ['b', 'a', 'b']);
          expect(
            app.queue.entries.map((e) => e.track.id),
            editDuringRequest ? ['b', 'a', 'b', 'a'] : ['b', 'a', 'b'],
          );
          await app.deletePlaylist(
            const LibraryItem(id: 'new', name: 'Copy', kind: ItemKind.playlist),
          );
          expect(app.serverPlaylist.item, null);
          expect(app.peekRoot(true)!.any((p) => p.id == 'new'), false);
          expect(app.queue.entries, same(queue));
          expect(server.contents.keys, ['p1', 'p2']);
          // A background catalog response may still contain the deleted item.
          server.staleListing = ['p1', 'p2', 'new'];
          await app.root(true);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(app.peekRoot(true)!.any((p) => p.id == 'new'), false);
        } finally {
          app.dispose();
          await store.write('flush', {});
          await directory.delete(recursive: true);
        }
      },
    );
  }
}
