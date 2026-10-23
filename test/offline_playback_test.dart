import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplefy/infrastructure/server_http_client.dart';
import 'package:simplefy/application/playback_availability.dart';
import 'package:simplefy/application/playback_coordinator.dart';
import 'package:simplefy/application/playback_ports.dart';
import 'package:simplefy/application/ports.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/domain/queue_engine.dart';
import 'recovery_safety_test.dart' show SourceAudio;

LibraryItem track(String id) =>
    LibraryItem(id: id, name: id, kind: ItemKind.track);

class Files implements PlaybackDownloads {
  Files(this.paths);
  final Map<String, String> paths;
  @override
  bool contains(String id) => paths.containsKey(id);
  @override
  String? localPath(String id) => paths[id];
  @override
  int? expectedBytes(String id) => null;
  @override
  Future<void> invalidate(String id) async {
    paths.remove(id);
  }
}

class Server implements PlaybackLibrary {
  bool hanging = false;
  int resolutions = 0, probes = 0;
  @override
  Future<RemotePlayback> resolvePlayback(
    LibraryItem track, {
    Duration position = Duration.zero,
  }) {
    resolutions++;
    return hanging
        ? Completer<RemotePlayback>().future
        : Future.value(
            RemotePlayback(Uri.parse('https://example.com/audio'), {}),
          );
  }

  @override
  Future<SourceAvailability> availability(LibraryItem track) async {
    probes++;
    return SourceAvailability.available;
  }

  @override
  Future<void> releaseStream(String session) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class BodyClient extends http.BaseClient {
  final body = StreamController<List<int>>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(body.stream, 200);
  @override
  void close() {
    unawaited(body.close());
  }
}

void main() {
  test(
    'blackholed requests fail quickly and share circuit state until recovery',
    () async {
      var attempts = 0;
      var reachable = false;
      final changes = <bool>[];
      final client = ServerHttpClient(
        MockClient((_) {
          attempts++;
          return reachable
              ? Future.value(http.Response('{}', 200))
              : Completer<http.Response>().future;
        }),
        readTimeout: const Duration(milliseconds: 20),
      );
      client.onConnectionChanged = changes.add;
      addTearDown(client.close);
      final uri = Uri.parse('https://example.com/Items');
      await expectLater(client.get(uri), throwsA(isA<TimeoutException>()));
      expect(client.unavailable, true);
      await expectLater(client.get(uri), throwsA(isA<SocketException>()));
      expect(attempts, 1);
      reachable = true;
      client.allowRetry();
      expect((await client.get(uri)).statusCode, 200);
      expect(client.unavailable, false);
      expect(changes, [false, true]);
    },
  );
  test(
    'HTTP errors are reachable responses and preserve API error handling',
    () async {
      final client = ServerHttpClient(
        MockClient((_) async => http.Response('{}', 503)),
      );
      addTearDown(client.close);
      final uri = Uri.parse('https://example.com/Items');
      expect((await client.get(uri)).statusCode, 503);
      expect(client.unavailable, false);
      expect((await client.get(uri)).statusCode, 503);
    },
  );
  test(
    'a stalled response body enters offline state within the read deadline',
    () async {
      final source = BodyClient();
      final client = ServerHttpClient(
        source,
        readTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(client.close);
      await expectLater(
        client.get(Uri.parse('https://example.com/Items')),
        throwsA(isA<TimeoutException>()),
      );
      expect(client.unavailable, true);
    },
  );

  for (final shuffle in [false, true]) {
    test(
      'offline rotation and history exclude remote tracks; reconnect restores them (shuffle=$shuffle)',
      () {
        var online = true;
        final policy = PlaybackAvailability(
          streamingAllowed: () => online,
          offline: () => !online,
          hasLocal: (item) => item.id == 'b' || item.id == 'd',
        );
        final queue = QueueEngine(random: Random(2))
          ..replace(['a', 'b', 'c', 'd'].map(track).toList());
        final original = queue.entries;
        queue.shuffled = shuffle;
        online = false;
        queue.setPlaybackFilter(policy.canPlay, version: 1);
        final played = [queue.next()!.track.id, queue.next()!.track.id];
        expect(played.toSet(), {'b', 'd'});
        expect(queue.next(), isNull);
        expect(queue.previous()!.track.id, played.first);
        expect(policy.isUnavailable(track('a')), true);
        expect(policy.isUnavailable(track('b')), false);
        online = true;
        queue.setPlaybackFilter(policy.canPlay, version: 2);
        expect(policy.isUnavailable(track('a')), false);
        queue.select(original.first.id);
        queue.shuffled = false;
        expect(queue.next()!.track.id, 'b');
        expect(queue.next()!.track.id, 'c');
        expect(identical(queue.entries, original), true);
      },
    );
  }
  test('repeat-one cannot retain an unavailable current song', () {
    final queue = QueueEngine()..replace([track('a'), track('b')]);
    queue.repeat = RepeatMode.one;
    queue.setPlaybackFilter((item) => item.id == 'b', version: 1);
    expect(queue.previewNext()!.track.id, 'b');
    expect(queue.next(automatic: true)!.track.id, 'b');
    expect(queue.next(automatic: true)!.track.id, 'b');
  });
  test(
    'remote timeout is bounded without a second availability request',
    () async {
      final queue = QueueEngine()..replace([track('a')]);
      final server = Server()..hanging = true;
      final audio = SourceAudio();
      final coordinator = player(queue, server, audio, Files({}), () => true);
      coordinator.wantsPlayback = true;
      await coordinator.start(queue.current);
      expect(server.resolutions, 1);
      expect(server.probes, 0);
      expect(audio.loaded, isEmpty);
      expect(coordinator.waitingForNetwork, true);
      coordinator.retryTimer?.cancel();
    },
  );
  test(
    'connection loss advances to local file; reconnect permits next remote occurrence',
    () async {
      final dir = await Directory.systemTemp.createTemp('simplefy-offline-');
      try {
        final file = File('${dir.path}/song.mp3');
        await file.writeAsBytes([1, 2, 3, 4]);
        final queue = QueueEngine()
          ..replace(['a', 'b', 'c'].map(track).toList());
        final snapshot = queue.entries;
        final files = Files({'b': file.path});
        var online = false;
        queue.setPlaybackFilter(
          (item) => online || files.contains(item.id),
          version: 1,
        );
        final audio = SourceAudio();
        final server = Server();
        final coordinator = player(queue, server, audio, files, () => online);
        coordinator.wantsPlayback = true;
        coordinator.loadedEntry = queue.current!.id;
        await coordinator.connectionLost();
        expect(queue.current!.track.id, 'b');
        expect(audio.loaded.single.scheme, 'file');
        expect(server.resolutions, 0);
        online = true;
        queue.setPlaybackFilter(
          (item) => online || files.contains(item.id),
          version: 2,
        );
        await coordinator.start(queue.next());
        expect(queue.current!.track.id, 'c');
        expect(audio.loaded.last.scheme, 'https');
        expect(identical(queue.entries, snapshot), true);
        coordinator.retryTimer?.cancel();
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}

PlaybackCoordinator player(
  QueueEngine queue,
  Server server,
  SourceAudio audio,
  Files files,
  bool Function() online,
) {
  Object? status;
  late PlaybackCoordinator result;
  result = PlaybackCoordinator(
    queue: queue,
    audio: audio,
    libraryProvider: () => server,
    downloadsProvider: () => files,
    prefetchProvider: () => null,
    importedPath: (_) => null,
    streamAllowed: online,
    changed: () {},
    notifyListeners: () {},
    message: (_) {},
    statusReader: () => status,
    statusWriter: (value) => status = value,
    next: (_) async {
      await result.start(queue.next());
    },
    pause: () async {},
    resume: () async {},
    applyNormalization: (_) async {},
    reportUnavailable: (_) {},
    resetSkipped: () {},
    sourceTimeout: const Duration(milliseconds: 20),
  );
  return result;
}
