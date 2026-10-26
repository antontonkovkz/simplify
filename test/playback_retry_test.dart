import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/application/ports.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/domain/queue_engine.dart';
import 'offline_playback_test.dart' as fixtures;
import 'recovery_safety_test.dart' show SourceAudio;

class TimeoutAudio extends SourceAudio {
  bool fail = true;
  Duration? resumedAt;
  @override
  Future<void> load(
    Uri uri,
    Map<String, String> headers, {
    Duration position = Duration.zero,
  }) async {
    if (fail) throw TimeoutException('native load');
    resumedAt = position;
    await super.load(uri, headers, position: position);
  }
}

class BrokenProbe extends fixtures.Server {
  @override
  Future<SourceAvailability> availability(LibraryItem track) async =>
      throw StateError('probe failed');
}

void main() {
  test(
    'native timeout retries same shuffle occurrence at requested position',
    () async {
      final queue = QueueEngine()
        ..replace([fixtures.track('a'), fixtures.track('b')])
        ..shuffled = true;
      final original = queue.current!.id;
      final audio = TimeoutAudio();
      final coordinator = fixtures.player(
        queue,
        fixtures.Server(),
        audio,
        fixtures.Files({}),
        () => true,
      )..wantsPlayback = true;
      addTearDown(() => coordinator.retryTimer?.cancel());
      await coordinator.start(
        queue.current,
        position: const Duration(seconds: 42),
      );
      expect(coordinator.waitingForNetwork, true);
      expect(coordinator.restoredPosition, 42000);
      expect(queue.current!.id, original);
      expect(queue.toJson()['visited'], hasLength(1));
      audio.fail = false;
      await coordinator.start(
        queue.current,
        position: Duration(milliseconds: coordinator.restoredPosition),
      );
      expect(coordinator.waitingForNetwork, false);
      expect(audio.resumedAt, const Duration(seconds: 42));
      expect(coordinator.loadedEntry, original);
    },
  );

  test('source timeout retains seek position for later reconnect', () async {
    final queue = QueueEngine()..replace([fixtures.track('a')]);
    final coordinator = fixtures.player(
      queue,
      fixtures.Server()..hanging = true,
      SourceAudio(),
      fixtures.Files({}),
      () => true,
    )..wantsPlayback = true;
    addTearDown(() => coordinator.retryTimer?.cancel());
    await coordinator.start(
      queue.current,
      position: const Duration(seconds: 63),
    );
    expect(coordinator.waitingForNetwork, true);
    expect(coordinator.restoredPosition, 63000);
  });

  test(
    'failed recovery probe schedules another attempt instead of stranding playback',
    () async {
      final queue = QueueEngine()..replace([fixtures.track('a')]);
      final coordinator = fixtures.player(
        queue,
        BrokenProbe(),
        SourceAudio(),
        fixtures.Files({}),
        () => true,
      )..wantsPlayback = true;
      addTearDown(() => coordinator.retryTimer?.cancel());
      await coordinator.start(queue.current);
      coordinator.onError(TimeoutException('buffering stalled'));
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.waitingForNetwork, true);
      expect(coordinator.retryTimer?.isActive, true);
      expect(coordinator.restoredPosition, 12000);
    },
  );
}
