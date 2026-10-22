import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/domain/queue_engine.dart';
import 'package:simplefy/infrastructure/jellyfin_library.dart';
import 'package:simplefy/infrastructure/track_preloader.dart';

LibraryItem song(String id) =>
    LibraryItem(id: id, name: id, kind: ItemKind.track, fileName: '$id.mp3');

void main() {
  test(
    'shuffle preview reserves the actual next occurrence without advancing',
    () {
      final queue = QueueEngine(random: Random(12))
        ..replace([song('a'), song('b'), song('a'), song('c')])
        ..shuffled = true;
      final start = queue.current!.id;
      final next = queue.previewNext()!;
      for (var i = 0; i < 8; i++) {
        expect(queue.previewNext()!.id, next.id);
      }
      expect(queue.current!.id, start);
      expect(queue.next(automatic: true)!.id, next.id);
      final removed = queue.previewNext()!;
      queue.remove(removed.id);
      expect(queue.previewNext()?.id, isNot(removed.id));
      expect(queue.next(automatic: true)?.id, isNot(removed.id));
    },
  );

  test(
    'preload preview respects repeat and does not alter previous history',
    () {
      final queue = QueueEngine()..replace([song('a'), song('b')]);
      expect(queue.previewNext()!.track.id, 'b');
      expect(queue.canPrevious, false);
      queue.repeat = RepeatMode.one;
      expect(queue.previewNext()!.id, queue.current!.id);
      expect(queue.next()!.track.id, 'b');
      queue.repeat = RepeatMode.all;
      expect(queue.previewNext()!.track.id, 'a');
      expect(queue.next(automatic: true)!.track.id, 'a');
    },
  );

  test(
    'rolling prefetch retains completed next file when network disappears',
    () async {
      final dir = await Directory.systemTemp.createTemp('simplefy-prefetch-');
      final library = JellyfinLibrary(
        const ServerSession('https://example.com', 'u', 'fake', 'u'),
      );
      var requests = 0;
      final cache = TrackPreloader(
        dir,
        library,
        clientFactory: () => MockClient((request) async {
          if (request.method == 'POST') return http.Response('', 404);
          requests++;
          expect(request.headers['Authorization'], contains('Token="fake"'));
          return http.Response('audio bytes', 200);
        }),
      );
      try {
        cache.prepare(song('b'), currentId: 'a', allowed: true);
        await cache.settled;
        final path = cache.localPath('b')!;
        expect(await File(path).readAsString(), 'audio bytes');
        cache.cancelPending();
        expect(cache.localPath('b'), path);
        cache.prepare(song('b'), currentId: 'a', allowed: false);
        expect(cache.localPath('b'), path);
        cache.prepare(song('c'), currentId: 'b', allowed: true);
        await cache.settled;
        expect(await File(path).exists(), true);
        expect(cache.localPath('c'), isNotNull);
        expect(requests, 2);
      } finally {
        cache.dispose();
        library.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test('superseded prefetch cannot publish an obsolete file', () async {
    final dir = await Directory.systemTemp.createTemp('simplefy-cancel-');
    final library = JellyfinLibrary(
      const ServerSession('https://example.com', 'u', 'fake', 'u'),
    );
    final first = Completer<http.Response>();
    final started = Completer<void>();
    final cache = TrackPreloader(
      dir,
      library,
      clientFactory: () => MockClient((request) {
        if (request.method == 'POST') {
          return Future.value(http.Response('', 404));
        }
        if (request.url.path.contains('/b/')) {
          started.complete();
          return first.future;
        }
        return Future.value(http.Response('c audio', 200));
      }),
    );
    try {
      cache.prepare(song('b'), currentId: 'a', allowed: true);
      await started.future;
      final obsolete = cache.settled;
      cache.prepare(song('c'), currentId: 'a', allowed: true);
      await cache.settled;
      first.complete(http.Response('obsolete', 200));
      await obsolete;
      expect(cache.localPath('b'), null);
      expect(cache.localPath('c'), isNotNull);
      expect(
        (await dir.list().toList()).where((e) => e.path.endsWith('.part')),
        isEmpty,
      );
    } finally {
      cache.dispose();
      library.close();
      await dir.delete(recursive: true);
    }
  });

  test(
    'oversized and failed prefetch never become playable cache entries',
    () async {
      final dir = await Directory.systemTemp.createTemp('simplefy-limit-');
      final library = JellyfinLibrary(
        const ServerSession('https://example.com', 'u', 'fake', 'u'),
      );
      final cache = TrackPreloader(
        dir,
        library,
        maximumBytes: 3,
        clientFactory: () => MockClient(
          (request) async => http.Response(
            request.method == 'POST' ? '' : 'too large',
            request.method == 'POST' ? 404 : 200,
          ),
        ),
      );
      try {
        cache.prepare(song('b'), currentId: 'a', allowed: true);
        await cache.settled;
        expect(cache.localPath('b'), null);
        expect(await dir.list().toList(), isEmpty);
      } finally {
        cache.dispose();
        library.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
