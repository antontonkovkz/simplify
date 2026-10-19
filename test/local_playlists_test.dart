import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/infrastructure/local_playlists.dart';
import 'package:simplefy/infrastructure/local_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const a = LibraryItem(id: 'server-a', name: 'A', kind: ItemKind.track);
  const b = LibraryItem(id: 'local:b', name: 'B', kind: ItemKind.track);
  late Directory directory;
  late LocalStore store;
  late LocalPlaylists playlists;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('simplefy-playlists-');
    store = LocalStore(directory);
    playlists = LocalPlaylists(store);
    await playlists.load('account-one');
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'snapshot preserves mixed sources, duplicates and order after reopening',
    () async {
      final queue = [a, b, a];
      final item = await playlists.save(queue, name: '  По дороге  ');
      queue.clear();
      expect(item.name, 'По дороге');
      expect(item.isLocalPlaylist, true);
      expect(item.isLocal, false);
      final reopened = LocalPlaylists(store);
      await reopened.load('account-one');
      expect(reopened.tracks(item.id).map((e) => e.id), [a.id, b.id, a.id]);
      expect(reopened.trackCount(item.id), 3);
      final occurrences = reopened.tracks(item.id);
      expect(identical(occurrences.first, occurrences.last), false);
      final copy = reopened.tracks(item.id)..clear();
      expect(copy, isEmpty);
      expect(reopened.tracks(item.id), hasLength(3));
    },
  );

  test(
    'overwrite retains identity, Save As creates independent snapshot',
    () async {
      final first = await playlists.save([a, b, a], name: 'Первый');
      final second = await playlists.save([b, a], name: 'Другой');
      final updated = await playlists.save([b, b], id: first.id);
      expect(updated.id, first.id);
      expect(updated.name, first.name);
      expect(playlists.tracks(first.id).map((e) => e.id), [b.id, b.id]);
      expect(playlists.tracks(second.id).map((e) => e.id), [b.id, a.id]);
      await playlists.delete(first.id);
      expect(playlists.item(first.id), null);
      expect(playlists.tracks(second.id), hasLength(2));
      expect(await store.read('state_account-one'), isEmpty);
    },
  );

  test(
    'explicit empty editor snapshot persists without allowing empty queues',
    () async {
      await expectLater(
        playlists.save([], name: 'Queue'),
        throwsFormatException,
      );
      final item = await playlists.save([], name: 'Empty', allowEmpty: true);
      final reopened = LocalPlaylists(store);
      await reopened.load('account-one');
      expect(reopened.item(item.id)?.name, 'Empty');
      expect(reopened.tracks(item.id), isEmpty);
    },
  );

  test('overlapping saves retain both playlists', () async {
    await Future.wait([
      playlists.save([a], name: 'Один'),
      playlists.save([b], name: 'Два'),
    ]);
    expect(playlists.items, hasLength(2));
    await playlists.load('account-one');
    expect(playlists.items, hasLength(2));
  });

  test('account isolation and rejected saves preserve existing data', () async {
    final first = await playlists.save([a], name: 'Музыка');
    await expectLater(
      playlists.save([b], name: ' музыка '),
      throwsFormatException,
    );
    await expectLater(playlists.save([b], name: ' '), throwsFormatException);
    await expectLater(playlists.save([], id: first.id), throwsFormatException);
    expect(playlists.tracks(first.id).single.id, a.id);
    await playlists.load('account-two');
    expect(playlists.items, isEmpty);
    await expectLater(playlists.save([b], id: first.id), throwsFormatException);
    await playlists.load('account-one');
    expect(playlists.item(first.id)?.name, 'Музыка');
  });
}
