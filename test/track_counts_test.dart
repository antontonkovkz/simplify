import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplefy/application/track_count_cache.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/infrastructure/jellyfin_library.dart';

void main() {
  test(
    'folder count requests only the recursive Audio total, not its contents',
    () async {
      final library = JellyfinLibrary(
        const ServerSession('https://example.com', 'u', 'fake', 'u'),
        client: MockClient((request) async {
          expect(request.url.path, '/Items');
          expect(request.url.queryParameters['IncludeItemTypes'], 'Audio');
          expect(request.url.queryParameters['Recursive'], 'true');
          expect(request.url.queryParameters['ParentId'], 'folder');
          expect(request.url.queryParameters['Limit'], '0');
          return http.Response(
            jsonEncode({'Items': [], 'TotalRecordCount': 1234}),
            200,
          );
        }),
      );
      expect(
        await library.trackCount(
          const LibraryItem(
            id: 'folder',
            name: 'Folder',
            kind: ItemKind.folder,
          ),
        ),
        1234,
      );
      library.close();
    },
  );

  test(
    'playlist count keeps repeated audio and excludes mixed-media entries across pages',
    () async {
      var requests = 0;
      final library = JellyfinLibrary(
        const ServerSession('https://example.com', 'u', 'fake', 'u'),
        client: MockClient((request) async {
          requests++;
          expect(request.url.path, '/Playlists/p/Items');
          final start = int.parse(request.url.queryParameters['StartIndex']!);
          return http.Response(
            jsonEncode({
              'TotalRecordCount': 302,
              'Items': start == 0
                  ? List.generate(
                      300,
                      (i) => {'Id': 'same-track', 'Type': 'Audio'},
                    )
                  : [
                      {'Id': 'video', 'Type': 'Video'},
                      {'Id': 'same-track', 'Type': 'Audio'},
                    ],
            }),
            200,
          );
        }),
      );
      expect(
        await library.trackCount(
          const LibraryItem(id: 'p', name: 'List', kind: ItemKind.playlist),
        ),
        301,
      );
      expect(requests, 2);
      library.close();
    },
  );

  test(
    'cache shares requests, persists totals and retains last value on failure',
    () async {
      Map<String, int>? saved;
      final cache = TrackCountCache(onChanged: (values) => saved = values);
      var calls = 0;
      final response = Completer<int>();
      Future<int> fetch() {
        calls++;
        return response.future;
      }

      final first = cache.resolve('p', fetch);
      final same = cache.resolve('p', fetch);
      response.complete(7);
      expect(await first, 7);
      expect(await same, 7);
      expect(calls, 1);
      expect(saved, {'p': 7});
      expect(await cache.resolve('p', () async => 99), 7);
      cache.invalidate();
      expect(
        await cache.resolve('p', () async => throw Exception('offline')),
        7,
      );
      expect(
        await cache.resolve('missing', () async => throw Exception('offline')),
        null,
      );
      expect(await cache.resolve('empty', () async => 0), 0);
      cache.dispose();
    },
  );

  test(
    'only three counts run at once and old account work cannot repopulate cache',
    () async {
      final cache = TrackCountCache(initial: {'old': 8});
      final responses = List.generate(5, (_) => Completer<int>());
      var started = 0;
      final jobs = List.generate(
        5,
        (i) => cache.resolve('$i', () {
          started++;
          return responses[i].future;
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(started, 3);
      cache.invalidate();
      for (final response in responses) {
        response.complete(4);
      }
      await Future.wait(jobs);
      expect(started, 3);
      expect(cache.peek('0'), null);
      expect(cache.peek('old'), 8);
      expect(await cache.resolve('0', () async => 9), 9);
      cache.dispose();
    },
  );
}
