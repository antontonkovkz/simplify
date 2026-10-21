import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/application/catalog_cache.dart';
import 'package:simplefy/domain/library_item.dart';

const old = LibraryItem(id: 'old', name: 'Old', kind: ItemKind.track);
const updated = LibraryItem(id: 'new', name: 'New', kind: ItemKind.track);

void main() {
  for (final key in ['collections', 'playlists', 'folder', 'recursive:album']) {
    test(
      '$key returns its saved snapshot before the network completes',
      () async {
        final values = <String, List<LibraryItem>>{
          key: [old],
        };
        var stored = 0;
        final cache = CatalogCache(
          values,
          onChanged: () {},
          onStored: () => stored++,
        );
        addTearDown(cache.dispose);
        final network = Completer<List<LibraryItem>>();
        expect(await cache.read(key, () => network.future), [old]);
        expect(cache.updating(key), true);
        network.complete([updated]);
        await Future<void>.delayed(Duration.zero);
        expect(values[key], [updated]);
        expect(stored, 1);
        expect(cache.updating(key), false);
        expect(() => values[key]!.add(old), throwsUnsupportedError);
      },
    );
  }

  test(
    'fresh reads join the in-flight request and wait for its result',
    () async {
      var calls = 0;
      final network = Completer<List<LibraryItem>>();
      final cache = CatalogCache(
        {
          'playlist': [old],
        },
        onChanged: () {},
        onStored: () {},
      );
      addTearDown(cache.dispose);
      Future<List<LibraryItem>> fetch() {
        calls++;
        return network.future;
      }

      expect(await cache.read('playlist', fetch), [old]);
      final fresh = cache.read('playlist', fetch, fresh: true);
      expect(calls, 1);
      network.complete([updated, old]);
      expect(await fresh, [updated, old]);
    },
  );

  test(
    'background failure keeps cached empty and nonempty snapshots',
    () async {
      final cache = CatalogCache(
        {
          'empty': [],
          'saved': [old],
        },
        onChanged: () {},
        onStored: () {},
      );
      addTearDown(cache.dispose);
      Future<List<LibraryItem>> fail() async => throw StateError('offline');
      expect(await cache.read('empty', fail), isEmpty);
      expect(await cache.read('saved', fail), [old]);
      await Future<void>.delayed(Duration.zero);
      expect(cache.errors.keys, containsAll(['empty', 'saved']));
      expect(cache.values['saved'], [old]);
      await expectLater(cache.read('missing', fail), throwsStateError);
    },
  );

  test(
    'account invalidation prevents a late response from replacing data',
    () async {
      final cache = CatalogCache({}, onChanged: () {}, onStored: () {});
      addTearDown(cache.dispose);
      final network = Completer<List<LibraryItem>>();
      final first = cache.read('playlists', () => network.future);
      final failure = expectLater(first, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      cache.invalidate();
      expect(await cache.read('playlists', () async => [updated]), [updated]);
      network.complete([old]);
      await failure;
      expect(cache.values['playlists'], [updated]);
    },
  );

  test(
    'playlist write invalidation prevents an old read undoing the saved contents',
    () async {
      final cache = CatalogCache(
        {
          'playlist': [old],
        },
        onChanged: () {},
        onStored: () {},
      );
      addTearDown(cache.dispose);
      final network = Completer<List<LibraryItem>>();
      expect(await cache.read('playlist', () => network.future), [old]);
      cache.invalidateKey('playlist');
      cache.values.remove('playlist');
      expect(await cache.read('playlist', () async => [updated]), [updated]);
      network.complete([old]);
      await Future<void>.delayed(Duration.zero);
      expect(cache.values['playlist'], [updated]);
    },
  );
}
