import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/application/playback_coordinator.dart';
import 'package:simplefy/application/playback_ports.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/domain/queue_engine.dart';
import 'offline_playback_test.dart' as fixtures;
import 'recovery_safety_test.dart' show SourceAudio;

class StreamingCache implements PlaybackPrefetch, PlaybackStreamingCache {
  final activated = <String>[];
  final address = Uri.parse('http://127.0.0.1:1234/opaque.mp3');
  @override
  void activate(String id) => activated.add(id);
  @override
  bool serves(String id) => true;
  @override
  Future<RemotePlayback> resolve(LibraryItem track) async =>
      RemotePlayback(address, const {});
  @override
  void cancelPending() =>
      throw StateError('A promoted cache must not be cancelled');
  @override
  String? localPath(String id) => null;
  @override
  Future<void> invalidate(String id) async {}
}

class CountingAudio extends SourceAudio {
  int pauses = 0;
  @override
  Future<void> pause() async {
    pauses++;
  }
}

void main() {
  test(
    'cache source survives connectivity loss until an actual underrun',
    () async {
      final queue = QueueEngine()
        ..replace([fixtures.track('a'), fixtures.track('b')]);
      final cache = StreamingCache();
      final audio = CountingAudio();
      final library = fixtures.Server();
      var online = true;
      Object? status;
      final playback = PlaybackCoordinator(
        queue: queue,
        audio: audio,
        libraryProvider: () => library,
        downloadsProvider: () => fixtures.Files({}),
        prefetchProvider: () => cache,
        importedPath: (_) => null,
        streamAllowed: () => online,
        changed: () {},
        notifyListeners: () {},
        message: (_) {},
        statusReader: () => status,
        statusWriter: (value) => status = value,
        next: (_) async {},
        pause: () async {},
        resume: () async {},
        applyNormalization: (_) async {},
        reportUnavailable: (_) {},
        resetSkipped: () {},
      )..wantsPlayback = true;
      addTearDown(() => playback.retryTimer?.cancel());
      await playback.start(queue.current);
      expect(audio.loaded.single, cache.address);
      expect(library.resolutions, 0);
      expect(audio.pauses, 1);
      online = false;
      await playback.connectionLost();
      expect(audio.pauses, 1);
      expect(playback.waitingForNetwork, false);
      expect(playback.wantsPlayback, true);
      playback.onError(TimeoutException('buffer exhausted'));
      await Future<void>.delayed(Duration.zero);
      expect(playback.waitingForNetwork, true);
      expect(audio.pauses, 2);
      expect(playback.retryTimer?.isActive, true);
      expect(queue.current!.track.id, 'a');
    },
  );
}
