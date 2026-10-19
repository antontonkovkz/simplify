import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplefy/application/ports.dart';
import 'package:simplefy/application/server_playlist_editor.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/infrastructure/jellyfin_library.dart';

void main() {
  const playlist = LibraryItem(id: 'p', name: '_test', kind: ItemKind.playlist);
  const a = LibraryItem(id: 'a', name: 'A', kind: ItemKind.track);
  const b = LibraryItem(id: 'b', name: 'B', kind: ItemKind.track);
  late ServerPlaylistEditor editor;
  late JellyfinLibrary library;
  late List<String> serverIds;
  late List<Map<String, dynamic>> writes;
  late int permissionStatus;
  late bool allowed;
  late bool missingTrack;
  late bool corruptSave;
  late int writeStatus;
  Completer<void>? validationWait;

  setUp(() {
    editor = ServerPlaylistEditor();
    serverIds = ['a', 'b'];
    writes = [];
    permissionStatus = 200;
    allowed = true;
    missingTrack = false;
    corruptSave = false;
    writeStatus = 204;
    validationWait = null;
    library = JellyfinLibrary(
      const ServerSession('https://example.com', 'user', 'fake', 'user'),
      client: MockClient((request) async {
        if (request.url.path == '/Playlists/p/Users/user') {
          return http.Response(
            jsonEncode({'CanEdit': allowed}),
            permissionStatus,
          );
        }
        if (request.url.path == '/Items') {
          await validationWait?.future;
          return http.Response(
            jsonEncode({
              'Items': missingTrack
                  ? []
                  : request.url.queryParameters['Ids']!
                        .split(',')
                        .map((id) => {'Id': id, 'Type': 'Audio'})
                        .toList(),
            }),
            200,
          );
        }
        if (request.url.path == '/Playlists/p' && request.method == 'GET') {
          return http.Response(
            jsonEncode({
              'ItemIds': serverIds,
              'Shares': [],
              'OpenAccess': true,
            }),
            200,
          );
        }
        if (request.url.path == '/Playlists/p' && request.method == 'POST') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          writes.add(body);
          if (writeStatus == 204) {
            serverIds = corruptSave ? [] : (body['Ids'] as List).cast<String>();
          }
          return http.Response('', writeStatus);
        }
        fail('Unexpected request: ${request.method} ${request.url.path}');
      }),
    );
  });
  tearDown(() {
    editor.dispose();
    library.close();
  });

  test(
    'owner/editor saves exact visible order and repeated occurrences with only Ids',
    () async {
      await editor.open(library, playlist, baseline: ['a', 'b']);
      expect(editor.access, PlaylistEditAccess.allowed);
      await editor.save(library, [b, a, b]);
      expect(serverIds, ['b', 'a', 'b']);
      expect(writes, [
        {
          'Ids': ['b', 'a', 'b'],
        },
      ]);
      // A second save compares against the newly saved baseline.
      await editor.save(library, [a]);
      expect(serverIds, ['a']);
      expect(editor.saving, false);
    },
  );

  test(
    'readers and public playlists cannot save; 403/404 permissions are denied',
    () async {
      for (final status in [200, 403, 404]) {
        allowed = false;
        permissionStatus = status;
        await editor.open(library, playlist, baseline: serverIds);
        expect(editor.access, PlaylistEditAccess.denied);
        await expectLater(
          editor.save(library, [a]),
          throwsA(isA<AppFailure>()),
        );
      }
      expect(writes, isEmpty);
      expect(serverIds, ['a', 'b']);
    },
  );

  test(
    'rights are rechecked before every save and server 403 is never success',
    () async {
      await editor.open(library, playlist, baseline: serverIds);
      allowed = false;
      await expectLater(
        editor.save(library, [a]),
        throwsA(isA<AppFailure>().having((e) => e.status, 'status', 403)),
      );
      expect(writes, isEmpty);
      allowed = true;
      writeStatus = 403;
      await expectLater(
        editor.save(library, [a]),
        throwsA(isA<AppFailure>().having((e) => e.status, 'status', 403)),
      );
      expect(serverIds, ['a', 'b']);
      expect(editor.access, PlaylistEditAccess.denied);
      expect(editor.saving, false);
    },
  );

  test(
    'server changes require explicit overwrite, never silent replacement',
    () async {
      await editor.open(library, playlist, baseline: ['a']);
      await expectLater(
        editor.save(library, [b]),
        throwsA(isA<ServerPlaylistConflict>()),
      );
      expect(writes, isEmpty);
      await editor.save(library, [b], overwriteChanged: true);
      expect(serverIds, ['b']);
    },
  );

  test(
    'local or missing tracks cannot silently disappear during save',
    () async {
      await editor.open(library, playlist, baseline: serverIds);
      await expectLater(
        editor.save(library, [
          const LibraryItem(id: 'local:a', name: 'A', kind: ItemKind.track),
        ]),
        throwsA(isA<AppFailure>()),
      );
      missingTrack = true;
      await expectLater(editor.save(library, [a]), throwsA(isA<AppFailure>()));
      expect(writes, isEmpty);
    },
  );

  test(
    'empty replacement is supported and mismatched result is reported',
    () async {
      await editor.open(library, playlist, baseline: serverIds);
      await editor.save(library, []);
      expect(serverIds, isEmpty);
      corruptSave = true;
      await expectLater(editor.save(library, [b]), throwsA(isA<AppFailure>()));
      expect(editor.saving, false);
    },
  );

  test(
    'provenance and baseline restore without trusting persisted permissions',
    () async {
      await editor.open(library, playlist, baseline: serverIds);
      final saved = editor.toJson();
      editor.clear();
      expect(editor.item, isNull);
      allowed = false;
      await editor.restore(library, saved);
      expect(editor.item?.id, playlist.id);
      expect(editor.access, PlaylistEditAccess.denied);
      allowed = true;
      await editor.save(library, [b]);
      expect(serverIds, ['b']);
      expect(ServerPlaylistEditor.sameIds(['AB-CD'], ['abcd']), true);
    },
  );

  test(
    'changing source during preflight cancels write and rejects concurrent saves',
    () async {
      await editor.open(library, playlist, baseline: serverIds);
      validationWait = Completer<void>();
      final first = editor.save(library, [a]);
      await expectLater(editor.save(library, [b]), throwsA(isA<AppFailure>()));
      editor.clear();
      validationWait!.complete();
      await expectLater(first, throwsA(isA<AppFailure>()));
      expect(writes, isEmpty);
      expect(editor.item, isNull);
    },
  );

  test(
    'unavailable permission API stays unknown and cannot authorize writing',
    () async {
      permissionStatus = 500;
      await editor.open(library, playlist, baseline: serverIds);
      expect(editor.access, PlaylistEditAccess.unavailable);
      await expectLater(editor.save(library, [a]), throwsA(isA<AppFailure>()));
      expect(writes, isEmpty);
    },
  );
  test(
    'refreshing granted rights retains the original conflict baseline',
    () async {
      allowed = false;
      await editor.open(library, playlist, baseline: serverIds);
      expect(editor.access, PlaylistEditAccess.denied);
      allowed = true;
      await editor.refreshAccess(library);
      expect(editor.access, PlaylistEditAccess.allowed);
      await editor.save(library, [b, a]);
      expect(serverIds, ['b', 'a']);
    },
  );

  test(
    'validation batches many unique IDs and does not deduplicate saved contents',
    () async {
      await editor.open(library, playlist, baseline: serverIds);
      final many = List.generate(
        301,
        (i) => LibraryItem(id: 'id$i', name: 'Track $i', kind: ItemKind.track),
      );
      await editor.save(library, [...many, many.first]);
      expect(serverIds.length, 302);
      expect(serverIds.first, serverIds.last);
    },
  );
}
