import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/domain/offline_availability.dart';
import 'package:simplefy/application/server_playlist_editor.dart';

const a = LibraryItem(id: 'aa', name: 'A', kind: ItemKind.track);
const b = LibraryItem(id: 'bb', name: 'B', kind: ItemKind.track);

void main() {
  test('partial and unknown snapshots cannot claim complete availability', () {
    final partial = OfflineAvailability.resolve(
      [a, b],
      total: 6,
      isAvailable: (_) => true,
    );
    expect(partial.available, 2);
    expect(partial.complete, false);
    final unknown = OfflineAvailability.resolve([a], isAvailable: (_) => true);
    expect(unknown.total, null);
    expect(unknown.complete, false);
    expect(const OfflineAvailability(available: 0, total: 0).complete, false);
  });
  test('playlist occurrences share files while retaining their own counts', () {
    final partial = OfflineAvailability.resolve(
      [a, b, a],
      total: 3,
      isAvailable: (track) => track.id == a.id,
      pending: {b.id},
    );
    expect(partial.available, 2);
    expect(partial.downloading, true);
    expect(partial.complete, false);
    expect(
      OfflineAvailability.resolve(
        [a, b, a],
        total: 3,
        isAvailable: (_) => true,
      ).complete,
      true,
    );
    final failed = OfflineAvailability.resolve(
      [a, b],
      total: 1,
      isAvailable: (_) => true,
      errors: {b.id},
    );
    expect(failed.failed, true);
    expect(failed.total, null);
    expect(failed.complete, false);
  });
  test(
    'queue changes compare ordered occurrences with the saved baseline',
    () async {
      final editor = ServerPlaylistEditor();
      await editor.open(
        null,
        const LibraryItem(
          id: 'playlist',
          name: 'Drive',
          kind: ItemKind.playlist,
        ),
        baseline: ['AA', 'b-b', 'aa'],
      );
      expect(editor.hasChanges(['aa', 'bb', 'aa']), false);
      expect(editor.hasChanges(['aa', 'aa', 'bb']), true);
      expect(editor.hasChanges(['aa', 'bb']), true);
      editor.clear();
      expect(editor.hasChanges(['aa']), false);
      editor.dispose();
    },
  );
}
