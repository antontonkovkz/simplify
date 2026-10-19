import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/domain/browse_location.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/infrastructure/local_music_library.dart';
import 'package:simplefy/infrastructure/local_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'installation identity survives updates and preserves bootstrap state',
    () async {
      final first = await Directory.systemTemp.createTemp('simplefy-identity-');
      final second = await Directory.systemTemp.createTemp(
        'simplefy-identity-',
      );
      try {
        final store = LocalStore(first);
        await store.write('installation', {'bootstrapApplied': true});
        final id = await store.installationId();
        expect(await LocalStore(first).installationId(), id);
        expect((await store.read('installation'))['bootstrapApplied'], true);
        expect(await LocalStore(second).installationId(), isNot(id));
      } finally {
        await first.delete(recursive: true);
        await second.delete(recursive: true);
      }
    },
  );
  test('browse restoration retains playlist and complete parent chain', () {
    final location = BrowseLocation(
      tab: 1,
      path: [
        const LibraryItem(id: 'p', name: 'Playlist', kind: ItemKind.playlist),
      ],
    );
    final restored = BrowseLocation.fromJson(location.toJson());
    expect(restored.tab, 1);
    expect(restored.path.single.id, 'p');
    expect(BrowseLocation.fromJson({}).path, isEmpty);
  });

  test(
    'local playback order follows visible names rather than import storage IDs',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'simplefy-local-order-',
      );
      try {
        final store = LocalStore(dir);
        await store.write('local_music', {
          'items': [
            for (final entry in [
              ('z-batch/0', 'A.mp3'),
              ('a-batch/9', 'C.mp3'),
              ('m-batch/1', 'B.mp3'),
            ])
              LibraryItem(
                id: 'local:${entry.$1}',
                name: '',
                kind: ItemKind.track,
                parentId: 'local:root',
                fileName: entry.$2,
                path: 'local_music/${entry.$1}/${entry.$2}',
              ).toJson(),
          ],
        });
        final library = LocalMusicLibrary(store);
        await library.initialize();
        expect(
          library.children(LocalMusicLibrary.root).map((e) => e.fileName),
          ['A.mp3', 'B.mp3', 'C.mp3'],
        );
        expect(library.tracks(LocalMusicLibrary.root).map((e) => e.fileName), [
          'A.mp3',
          'B.mp3',
          'C.mp3',
        ]);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'imported hierarchy survives reopening and deleting copies preserves originals',
    () async {
      final dir = await Directory.systemTemp.createTemp('simplefy-local-');
      final original = File('${dir.path}/original.mp3');
      await original.writeAsString('original');
      final file = File('${dir.path}/local_music/batch/Album/song.mp3');
      await file.parent.create(recursive: true);
      await file.writeAsString('copy');
      const folder = LibraryItem(
        id: 'local:batch:Album',
        name: 'Album',
        kind: ItemKind.folder,
        parentId: 'local:root',
        path: 'local_music/batch/Album',
      );
      const track = LibraryItem(
        id: 'local:batch:Album/song.mp3',
        name: 'Song',
        kind: ItemKind.track,
        parentId: 'local:batch:Album',
        path: 'local_music/batch/Album/song.mp3',
        fileName: 'song.mp3',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            LocalMusicLibrary.channel,
            (call) async => [folder.toJson(), track.toJson()],
          );
      try {
        final library = LocalMusicLibrary(LocalStore(dir));
        await library.initialize();
        expect(await library.import(folder: true), 1);
        expect(library.children(LocalMusicLibrary.root).single.id, folder.id);
        expect(library.tracks(folder).single.id, track.id);
        expect(library.trackCount(folder), 1);
        expect(library.trackCount(LocalMusicLibrary.root), 1);
        expect(
          library.tracks(LocalMusicLibrary.root, recursive: false),
          isEmpty,
        );
        final restored = LocalMusicLibrary(LocalStore(dir));
        await restored.initialize();
        expect(restored.pathFor(restored.tracks(folder).single), file.path);
        await restored.remove(folder);
        expect(restored.isEmpty, true);
        expect(restored.trackCount(LocalMusicLibrary.root), 0);
        expect(await file.exists(), false);
        expect(await original.readAsString(), 'original');
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(LocalMusicLibrary.channel, null);
        await dir.delete(recursive: true);
      }
    },
  );
}
