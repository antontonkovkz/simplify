import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplefy/application/ports.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/infrastructure/jellyfin_library.dart';

const track = LibraryItem(
  id: 'track',
  name: 'Track',
  kind: ItemKind.track,
  fileName: 'track.dsf',
);
void main() {
  for (final android in [false, true]) {
    test(
      'PlaybackInfo supplies a platform profile and overrides extension guesses (android=$android)',
      () async {
        final api = JellyfinLibrary(
          const ServerSession('https://example.com', 'u', 'fixture', 'u'),
          android: android,
          client: MockClient((request) async {
            expect(request.method, 'POST');
            expect(request.url.path, '/Items/track/PlaybackInfo');
            final body = jsonDecode(request.body) as Map;
            final profile = body['DeviceProfile'] as Map;
            final direct =
                (profile['DirectPlayProfiles'] as List).single as Map;
            expect((direct['Container'] as String).contains('ogg'), android);
            expect(body['StartTimeTicks'], 120000000);
            return http.Response(
              jsonEncode({
                'MediaSources': [
                  {'Id': 'source', 'SupportsDirectPlay': true},
                ],
              }),
              200,
            );
          }),
        );
        try {
          expect(api.requiresConversion(track), true);
          final source = await api.resolvePlayback(
            track,
            position: const Duration(seconds: 12),
          );
          expect(source.uri.path, '/Audio/track/stream');
          expect(source.uri.queryParameters['static'], 'true');
          expect(api.requiresConversion(track), false);
        } finally {
          api.close();
        }
      },
    );
  }
  test(
    'negotiated transcode stays on origin and uses headers instead of a URL token',
    () async {
      final api = JellyfinLibrary(
        const ServerSession('https://example.com', 'u', 'fixture', 'u'),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'PlaySessionId': 'play',
              'MediaSources': [
                {
                  'SupportsDirectPlay': false,
                  'TranscodingUrl':
                      '/Audio/track/stream.mp3?api_key=fixture&AudioCodec=mp3',
                },
              ],
            }),
            200,
          ),
        ),
      );
      try {
        final source = await api.resolvePlayback(track);
        expect(source.uri.path, '/Audio/track/stream.mp3');
        expect(source.uri.queryParameters.containsKey('api_key'), false);
        expect(source.headers['Authorization'], contains('Token='));
        expect(source.playSessionId, 'play');
        expect(api.requiresConversion(track), true);
      } finally {
        api.close();
      }
    },
  );
  test(
    'server cannot redirect authenticated playback to an unrelated host',
    () async {
      final api = JellyfinLibrary(
        const ServerSession('https://example.com', 'u', 'fixture', 'u'),
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'MediaSources': [
                {'TranscodingUrl': 'https://other.example/steal'},
              ],
            }),
            200,
          ),
        ),
      );
      try {
        await expectLater(
          api.resolvePlayback(track),
          throwsA(isA<AppFailure>()),
        );
      } finally {
        api.close();
      }
    },
  );
  test(
    'download negotiation coalesces, caches only the decision, and supports older servers',
    () async {
      var calls = 0;
      final gate = Completer<void>();
      final api = JellyfinLibrary(
        const ServerSession('https://example.com', 'u', 'fixture', 'u'),
        android: true,
        client: MockClient((_) async {
          calls++;
          await gate.future;
          return http.Response('', 405);
        }),
      );
      try {
        const opus = LibraryItem(
          id: 'opus',
          name: 'Opus',
          kind: ItemKind.track,
          fileName: 'song.opus',
        );
        final first = api.prepareDownload(opus);
        final second = api.prepareDownload(opus);
        gate.complete();
        await Future.wait([first, second]);
        expect(calls, 1);
        expect(api.requiresConversion(opus), false);
        await api.prepareDownload(opus);
        expect(calls, 1);
        expect(api.requiresConversion(track), true);
      } finally {
        api.close();
      }
    },
  );
}
