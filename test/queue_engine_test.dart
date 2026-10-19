import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/domain/queue_engine.dart';

LibraryItem track(String id) => LibraryItem(
  id: id,
  name: id,
  kind: ItemKind.track,
  fileName: '$id.flac',
  artist: 'Artist',
);

void main() {
  test('empty queue has no previous or next', () {
    final queue = QueueEngine();
    expect(queue.canPrevious, false);
    expect(queue.next(), null);
    expect(queue.previous(), null);
  });
  test('selected playlist track continues with its following track', () {
    final queue = QueueEngine()
      ..replace([track('a'), track('b'), track('c')], start: 1);
    expect(queue.current!.track.id, 'b');
    expect(queue.next()!.track.id, 'c');
    expect(queue.next(), null);
  });
  test(
    'previous reaches earlier playlist entries even when starting in the middle',
    () {
      final queue = QueueEngine()
        ..replace([track('a'), track('b'), track('c')], start: 2);
      expect(queue.canPrevious, true);
      expect(queue.previous()!.track.id, 'b');
      expect(queue.previous()!.track.id, 'a');
      expect(queue.canPrevious, false);
      expect(queue.next()!.track.id, 'b');
    },
  );
  test('append preserves current and keeps duplicate occurrences', () {
    final queue = QueueEngine()..replace([track('a')]);
    final current = queue.current!.id;
    queue.append([track('a'), track('b')]);
    expect(queue.current!.id, current);
    expect(queue.entries.map((e) => e.id).toSet(), hasLength(3));
    expect(queue.next()!.track.id, 'a');
  });
  test('shuffle visits every occurrence once without changing list order', () {
    final queue = QueueEngine(random: Random(7))
      ..replace([track('a'), track('b'), track('a'), track('d')])
      ..shuffled = true;
    final order = queue.entries.map((e) => e.id).toList();
    final played = <String>[queue.current!.id];
    while (true) {
      final next = queue.next();
      if (next == null) break;
      played.add(next.id);
      expect(played.length, lessThanOrEqualTo(4));
    }
    expect(played.toSet(), hasLength(4));
    expect(queue.entries.map((e) => e.id), order);
  });
  test('shuffle previous and forward traverse actual playback history', () {
    final queue = QueueEngine(random: Random(12))
      ..replace(List.generate(8, (i) => track('$i')))
      ..shuffled = true;
    final first = queue.current!.id;
    final second = queue.next()!.id;
    final third = queue.next()!.id;
    expect(queue.previous()!.id, second);
    expect(queue.previous()!.id, first);
    expect(queue.next()!.id, second);
    expect(queue.next()!.id, third);
  });
  test(
    'removal of current can leave it playing and advance to original successor',
    () {
      final queue = QueueEngine()
        ..replace([track('a'), track('b'), track('c')], start: 1);
      expect(queue.remove(queue.current!.id), true);
      expect(queue.detached, true);
      expect(queue.current!.track.id, 'b');
      expect(queue.next()!.track.id, 'c');
    },
  );
  test('deleting an earlier row while detached preserves the successor', () {
    final queue = QueueEngine()
      ..replace([track('a'), track('b'), track('c')], start: 1);
    queue.remove(queue.current!.id);
    queue.remove(queue.entries.first.id);
    expect(queue.next()!.track.id, 'c');
  });
  test(
    'removing the last current record terminates without an invalid index',
    () {
      final queue = QueueEngine()..replace([track('a')]);
      queue.remove(queue.current!.id);
      expect(queue.next(), null);
      expect(queue.current!.track.id, 'a');
    },
  );
  test(
    'reordering affects next in sequential mode and preserves active identity',
    () {
      final queue = QueueEngine()
        ..replace([track('a'), track('b'), track('c')]);
      final active = queue.current!.id;
      queue.move(2, 1);
      expect(queue.current!.id, active);
      expect(queue.next()!.track.id, 'c');
    },
  );
  test('repeat one affects automatic completion, not explicit next', () {
    final queue = QueueEngine()
      ..replace([track('a'), track('b')])
      ..repeat = RepeatMode.one;
    expect(queue.next(automatic: true)!.track.id, 'a');
    expect(queue.next()!.track.id, 'b');
  });
  test('repeat all restarts sequential queue', () {
    final queue = QueueEngine()
      ..replace([track('a'), track('b')])
      ..repeat = RepeatMode.all;
    expect(queue.next()!.track.id, 'b');
    expect(queue.next()!.track.id, 'a');
  });
  test(
    'leaving shuffle follows visible order rather than a random forward branch',
    () {
      final queue = QueueEngine(random: Random(5))
        ..replace(List.generate(6, (i) => track('$i')))
        ..shuffled = true;
      queue.next();
      queue.next();
      queue.previous();
      queue.shuffled = false;
      final index = queue.entries.indexWhere((e) => e.id == queue.current!.id);
      expect(queue.next()?.track.id, index == 5 ? null : '${index + 1}');
    },
  );
  test(
    'persistence keeps duplicate IDs, detached audio, modes and history',
    () {
      final queue = QueueEngine(random: Random(1))
        ..replace([track('a'), track('b'), track('a')])
        ..shuffled = true
        ..repeat = RepeatMode.all;
      queue.next();
      queue.remove(queue.current!.id);
      final restored = QueueEngine()..restore(queue.toJson());
      expect(restored.toJson(), queue.toJson());
      expect(restored.detached, true);
      expect(restored.canPrevious, true);
    },
  );
}
