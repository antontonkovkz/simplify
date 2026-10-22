import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/domain/library_search.dart';
import 'package:simplefy/infrastructure/jellyfin_library.dart';
import 'package:simplefy/infrastructure/local_store.dart';
import 'package:simplefy/infrastructure/download_manager.dart';
import 'package:simplefy/application/ports.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('playlist origin uses the source path and survives cached metadata', () {
    for (final extension in [
      'm3u',
      'M3U8',
      'pls',
      'wpl',
      'zpl',
      'asx',
      'xspf',
    ]) {
      final item = JellyfinLibrary.parse({
        'Id': 'file',
        'Name': 'Album',
        'Type': 'Playlist',
        'Path': 'C:\\Music\\Album.$extension',
      });
      expect(item.isFilePlaylist, true);
      expect(LibraryItem.fromJson(item.toJson()).isFilePlaylist, true);
    }
    for (final path in [
      '',
      '/config/playlists/Main',
      '/config/playlists/Main/playlist.xml',
    ]) {
      expect(
        LibraryItem(
          id: 'native',
          name: 'A misleading.m3u',
          kind: ItemKind.playlist,
          path: path,
        ).isFilePlaylist,
        false,
      );
    }
    expect(
      const LibraryItem(
        id: 'local-playlist:copy',
        name: 'Copy',
        kind: ItemKind.playlist,
        path: '/album.m3u',
      ).isFilePlaylist,
      false,
    );
    expect(
      const LibraryItem(
        id: 'track',
        name: 'Track',
        kind: ItemKind.track,
        path: '/album.m3u',
      ).isFilePlaylist,
      false,
    );
  });

  test('missing artist or title falls back to filename without extension', () {
    const item = LibraryItem(
      id: '1',
      name: 'Tagged title',
      kind: ItemKind.track,
      fileName: '03 - Song.flac',
    );
    expect(item.title, '03 - Song');
    expect(item.subtitle, '');
    expect(item.filenameTitle, '03 - Song');
  });
  test('physical directory name takes precedence over album tags', () {
    final folder = JellyfinLibrary.parse({
      'Id': 'album',
      'Name': 'Tagged album title',
      'Type': 'MusicAlbum',
      'Path': '/music/2000 - Original directory',
    });
    expect(folder.name, '2000 - Original directory');
    expect(folder.kind, ItemKind.folder);
  });
  test('unsupported formats use compatible stream and downloaded file', () {
    final library = JellyfinLibrary(
      const ServerSession('https://example.com', 'u', 'fake', 'u'),
    );
    const ape = LibraryItem(
      id: 'ape',
      name: 'Album',
      kind: ItemKind.track,
      fileName: 'album.ape',
    );
    const flac = LibraryItem(
      id: 'flac',
      name: 'Song',
      kind: ItemKind.track,
      fileName: 'song.flac',
    );
    expect(library.streamUri(ape).path, '/Audio/ape/stream.mp3');
    expect(library.streamUri(ape).queryParameters.containsKey('api_key'), false);
    expect(library.downloadUri(ape).path, '/Audio/ape/stream.mp3');
    expect(library.downloadUri(flac).path, '/Items/flac/Download');
    library.close();
  });
  test(
    'server failure cannot become a deletion plan; explicit 404 can',
    () async {
      const source = LibraryItem(
        id: 'source',
        name: 'Saved folder',
        kind: ItemKind.folder,
      );
      for (final status in [404, 500, 401]) {
        final library = JellyfinLibrary(
          const ServerSession('https://example.com', 'u', 'fake', 'u'),
          client: MockClient((request) async => http.Response('{}', status)),
        );
        final manager = DownloadManager(
          LocalStore(Directory.systemTemp),
          library,
        );
        if (status == 404) {
          expect((await manager.snapshot(source)).tracks, isEmpty);
        } else {
          await expectLater(
            manager.snapshot(source),
            throwsA(isA<AppFailure>()),
          );
        }
        expect(manager.groups, isEmpty);
        manager.dispose();
        library.close();
      }
    },
  );
  test('search uses all three track fields and excludes folders', () {
    const item = LibraryItem(
      id: '1',
      name: 'Yesterday',
      artist: 'The Beatles',
      fileName: '03 - original.flac',
      kind: ItemKind.track,
    );
    expect(item.matches('beatles'), true);
    expect(item.matches('ORIGINAL'), true);
    expect(item.matches('yesterday'), true);
    expect(
      const LibraryItem(
        id: '2',
        name: 'Beatles',
        kind: ItemKind.folder,
      ).matches('Beatles'),
      false,
    );
  });
  test('worker search retains playlist occurrence identity', () async {
    const first = LibraryItem(id: 'same', name: 'Song', kind: ItemKind.track);
    final duplicate = LibraryItem(
      id: 'same',
      name: 'Song',
      kind: ItemKind.track,
    );
    final source = [first, duplicate];
    final found = await findTracks(source, 'song');
    expect(identical(found[0], source[0]), true);
    expect(identical(found[1], source[1]), true);
    expect(source.indexOf(found[1]), 1);
  });
  test('API preserves physical folders including MusicArtist items', () async {
    final library = JellyfinLibrary(
      const ServerSession('https://example.com', 'user', 'fake', 'user'),
      client: MockClient((request) async {
        expect(request.url.path, '/Items');
        expect(request.url.queryParameters['Recursive'], 'false');
        expect(request.headers['Authorization'], contains('Token="fake"'));
        return http.Response(
          jsonEncode({
            'TotalRecordCount': 2,
            'Items': [
              {
                'Id': 'folder',
                'Name': 'radio',
                'Type': 'MusicArtist',
                'Path': '/music/radio',
              },
              {
                'Id': 'audio',
                'Name': 'Title',
                'Artists': ['Singer'],
                'Type': 'Audio',
                'Path': '/music/03. File.m4a',
                'ParentId': 'root',
              },
            ],
          }),
          200,
        );
      }),
    );
    final items = await library.children(
      const LibraryItem(id: 'root', name: 'Music', kind: ItemKind.collection),
    );
    expect(items.first.kind, ItemKind.folder);
    expect(items.last.fileName, '03. File.m4a');
    expect(items.last.title, 'Title');
  });
  test('playlist endpoint keeps server order and duplicate tracks', () async {
    final library = JellyfinLibrary(
      const ServerSession('https://example.com', 'u', 'fake', 'u'),
      client: MockClient((request) async {
        expect(request.url.path, '/Playlists/p/Items');
        return http.Response(
          jsonEncode({
            'TotalRecordCount': 3,
            'Items': [
              for (final id in ['z', 'a', 'z'])
                {'Id': id, 'Name': id, 'Type': 'Audio'},
            ],
          }),
          200,
        );
      }),
    );
    final items = await library.tracks(
      const LibraryItem(id: 'p', name: 'Playlist', kind: ItemKind.playlist),
    );
    expect(items.map((e) => e.id), ['z', 'a', 'z']);
  });
  test('paginated responses do not silently truncate library', () async {
    var calls = 0;
    final library = JellyfinLibrary(
      const ServerSession('https://example.com', 'u', 'fake', 'u'),
      client: MockClient((request) async {
        final offset = int.parse(request.url.queryParameters['StartIndex']!);
        calls++;
        return http.Response(
          jsonEncode({
            'TotalRecordCount': 301,
            'Items': [
              for (var i = offset; i < (offset == 0 ? 300 : 301); i++)
                {'Id': '$i', 'Name': '$i', 'Type': 'Audio'},
            ],
          }),
          200,
        );
      }),
    );
    expect(
      await library.tracks(
        const LibraryItem(id: 'r', name: 'R', kind: ItemKind.folder),
      ),
      hasLength(301),
    );
    expect(calls, 2);
  });
  test('local snapshots serialize writes and survive reopening', () async {
    final dir = await Directory.systemTemp.createTemp('simplefy-test-');
    try {
      final store = LocalStore(dir);
      await Future.wait(
        List.generate(
          8,
          (i) => store.write('state', {
            'revision': i,
            'items': [i],
          }),
        ),
      );
      expect(await LocalStore(dir).read('state'), {
        'revision': 7,
        'items': [7],
      });
      expect(await File('${dir.path}/state.json.tmp').exists(), false);
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test(
    'versioned storage reads initial snapshots and preserves malformed originals',
    () async {
      final dir = await Directory.systemTemp.createTemp('simplefy-version-');
      try {
        final store = LocalStore(dir);
        await File('${dir.path}/legacy.json').writeAsString('{"value":42}');
        expect(await store.read('legacy'), {'value': 42});
        await store.write('legacy', {'value': 43});
        final encoded =
            jsonDecode(await File('${dir.path}/legacy.json').readAsString())
                as Map;
        expect(encoded['schemaVersion'], 1);
        expect(await store.read('legacy'), {'value': 43});
        await File('${dir.path}/damaged.json').writeAsString('not json');
        expect(await store.read('damaged'), isEmpty);
        expect(
          await File('${dir.path}/damaged.json.damaged').readAsString(),
          'not json',
        );
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
