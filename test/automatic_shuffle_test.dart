import 'package:simplefy/application/playback_coordinator.dart';
import 'package:simplefy/infrastructure/playback_audio.dart';
import 'offline_playback_test.dart' as fixtures;
import 'recovery_safety_test.dart' show SourceAudio;
import 'dart:async';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:simplefy/infrastructure/music_audio_handler.dart';
import 'package:simplefy/domain/queue_engine.dart';
import 'package:simplefy/domain/library_item.dart';

class EventPlayer implements AudioPlayer {
  final states = StreamController<PlayerState>.broadcast(sync: true);
  final events = StreamController<PlaybackEvent>.broadcast(sync: true);
  final errors = StreamController<PlayerException>.broadcast(sync: true);
  @override
  ProcessingState processingState = ProcessingState.ready;
  @override
  bool playing = true;
  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<PlaybackEvent> get playbackEventStream => events.stream;
  @override
  Stream<PlayerException> get errorStream => errors.stream;
  @override
  Duration get position => Duration.zero;
  @override
  Duration get bufferedPosition => Duration.zero;
  @override
  double get speed => 1;
  void emit(ProcessingState state, {bool playing = true}) {
    processingState = state;
    this.playing = playing;
    states.add(PlayerState(playing, state));
  }

  int loads = 0;
  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    loads++;
    emit(ProcessingState.loading, playing: false);
    emit(ProcessingState.ready, playing: false);
    return const Duration(seconds: 10);
  }

  @override
  Future<void> pause() async {
    emit(processingState, playing: false);
  }

  @override
  Future<void> stop() async {
    emit(ProcessingState.idle, playing: false);
  }

  @override
  Future<void> play() async {
    emit(processingState);
  }

  Future<void> close() async {
    await states.close();
    await events.close();
    await errors.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class SlowAudio extends SourceAudio {
  @override
  Future<void> load(
    Uri uri,
    Map<String, String> headers, {
    Duration position = Duration.zero,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 60));
    await super.load(uri, headers, position: position);
  }
}

void main() {
  test(
    'buffering watchdog recovers once and cancels on ready or pause',
    () async {
      final player = EventPlayer();
      final handler = MusicAudioHandler(
        player: player,
        bufferingTimeout: const Duration(milliseconds: 20),
      );
      final failures = <Object>[];
      handler.onError = failures.add;
      handler.shouldAutoAdvance = () => player.playing;
      player.emit(ProcessingState.buffering);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      player.emit(ProcessingState.ready);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(failures, isEmpty);
      player.emit(ProcessingState.buffering);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(failures.single, isA<TimeoutException>());
      player.emit(ProcessingState.buffering);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(failures, hasLength(1));
      player.emit(ProcessingState.ready);
      player.emit(ProcessingState.buffering);
      await player.pause();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(failures, hasLength(1));
      await player.close();
    },
  );

  test(
    'server timeout does not exhaust shuffle visits or disable manual next after recovery',
    () async {
      final queue = QueueEngine(random: Random(4))
        ..replace(
          List.generate(
            6,
            (i) => LibraryItem(id: '$i', name: '$i', kind: ItemKind.track),
          ),
        )
        ..shuffled = true;
      final entries = queue.entries;
      final original = queue.current!.id;
      final audio = SourceAudio();
      final server = fixtures.Server()..hanging = true;
      final coordinator = fixtures.player(
        queue,
        server,
        audio,
        fixtures.Files({}),
        () => true,
      )..wantsPlayback = true;
      await coordinator.start(queue.current);
      coordinator.retryTimer?.cancel();
      expect(server.resolutions, 1);
      expect(queue.current!.id, original);
      expect(queue.toJson()['visited'], hasLength(1));
      expect(queue.toJson()['history'], hasLength(1));
      expect(identical(queue.entries, entries), true);
      server.hanging = false;
      await coordinator.start(queue.current);
      final played = <String>{queue.current!.id};
      for (var i = 1; i < 6; i++) {
        final next = queue.next(automatic: i.isEven);
        expect(next, isNotNull);
        await coordinator.start(next);
        expect(coordinator.loadedEntry, next!.id);
        expect(played.add(next.id), true);
      }
      expect(played, hasLength(6));
      coordinator.retryTimer?.cancel();
    },
  );

  test(
    'slow native audio preparation is not subject to the short API deadline',
    () async {
      final queue = QueueEngine()
        ..replace([
          const LibraryItem(id: 'a', name: 'A', kind: ItemKind.track),
        ]);
      final audio = SlowAudio();
      final server = fixtures.Server();
      final coordinator = fixtures.player(
        queue,
        server,
        audio,
        fixtures.Files({}),
        () => true,
      )..wantsPlayback = true;
      await coordinator.start(queue.current);
      expect(coordinator.loadedEntry, queue.current!.id);
      expect(coordinator.waitingForNetwork, false);
      expect(audio.loaded, hasLength(1));
      expect(server.probes, 0);
      coordinator.retryTimer?.cancel();
    },
  );

  test(
    'end-of-track events load and start every shuffle occurrence through the real coordinator',
    () async {
      final player = EventPlayer();
      final handler = MusicAudioHandler(player: player);
      final queue = QueueEngine(random: Random(3))
        ..replace(
          List.generate(
            6,
            (i) => LibraryItem(id: '$i', name: '$i', kind: ItemKind.track),
          ),
        )
        ..shuffled = true;
      final server = fixtures.Server();
      Object? status;
      late PlaybackCoordinator coordinator;
      coordinator = PlaybackCoordinator(
        queue: queue,
        audio: PlaybackAudioAdapter(handler),
        libraryProvider: () => server,
        downloadsProvider: () => fixtures.Files({}),
        prefetchProvider: () => null,
        importedPath: (_) => null,
        streamAllowed: () => true,
        changed: () {},
        notifyListeners: () {},
        message: (_) {},
        statusReader: () => status,
        statusWriter: (value) => status = value,
        next: (automatic) async {
          final next = queue.next(automatic: automatic);
          if (next != null) await coordinator.start(next);
        },
        pause: () async {},
        resume: () async {},
        applyNormalization: (_) async {},
        reportUnavailable: (_) {},
        resetSkipped: () {},
      );
      handler.shouldAutoAdvance = () =>
          coordinator.wantsPlayback &&
          !coordinator.waitingForNetwork &&
          coordinator.loadedEntry == queue.current?.id;
      handler.onNext = (automatic) => coordinator.next(automatic);
      coordinator.wantsPlayback = true;
      await coordinator.start(queue.current);
      final visited = <String>{queue.current!.id};
      for (var i = 1; i < 6; i++) {
        player.emit(ProcessingState.completed, playing: false);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(coordinator.loadedEntry, queue.current!.id);
        expect(player.playing, true);
        expect(visited.add(queue.current!.id), true);
      }
      expect(player.loads, 6);
      expect(server.resolutions, 6);
      coordinator.wantsPlayback = false;
      player.emit(ProcessingState.completed, playing: false);
      await Future<void>.delayed(Duration.zero);
      expect(player.loads, 6);
      coordinator.retryTimer?.cancel();
      await player.close();
    },
  );

  test(
    'native completion advances shuffle once even if native playing is already false',
    () async {
      final player = EventPlayer();
      final handler = MusicAudioHandler(player: player);
      final queue = QueueEngine(random: Random(7))
        ..replace(
          List.generate(
            5,
            (i) => LibraryItem(id: '$i', name: '$i', kind: ItemKind.track),
          ),
        )
        ..shuffled = true;
      var wantsPlayback = true;
      handler.shouldAutoAdvance = () => wantsPlayback;
      final played = [queue.current!.id];
      handler.onNext = (automatic) async {
        expect(automatic, true);
        final entry = queue.next(automatic: automatic);
        if (entry != null) played.add(entry.id);
      };
      for (var i = 0; i < 4; i++) {
        player.emit(ProcessingState.ready);
        player.emit(ProcessingState.completed, playing: false);
        player.emit(ProcessingState.completed, playing: false);
        await Future<void>.delayed(Duration.zero);
      }
      expect(played.toSet(), hasLength(5));
      expect(played, hasLength(5));
      wantsPlayback = false;
      player.emit(ProcessingState.ready, playing: false);
      player.emit(ProcessingState.completed, playing: false);
      expect(played, hasLength(5));
      await player.close();
    },
  );
}
