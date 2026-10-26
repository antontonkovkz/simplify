import '../application/diagnostics.dart';
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/foundation.dart';

import '../domain/queue_engine.dart';
import '../application/playback_gain.dart';

class MusicAudioHandler extends BaseAudioHandler {
  final AudioPlayer player;
  late final _gain = PlaybackGain(player.setVolume);
  Future<void> setPlaybackGain(double volume, {bool smooth = false}) =>
      _gain.set(volume, smooth: smooth);
  void cancelGainAdjustment() => _gain.cancel();
  Future<void> Function()? onPlay;
  Future<void> Function()? onPause;
  Future<void> Function()? onStop;
  Future<void> Function(bool automatic)? onNext;
  Future<void> Function()? onPrevious;
  Future<void> Function(int index)? onSelect;
  Future<void> Function(Duration position)? onSeek;
  void Function(bool value)? onShuffle;
  void Function(RepeatMode mode)? onRepeat;
  void Function(Object error)? onError;
  bool canGoPrevious = false;
  bool _loading = false;
  int _loadGeneration = 0;
  bool Function()? shouldAutoAdvance;
  bool _completionHandled = false;
  final Duration bufferingTimeout;
  Timer? _bufferingTimer;
  int? _bufferingGeneration;

  void _watchBuffering(ProcessingState state, bool playing) {
    if (state != ProcessingState.buffering || !playing || _loading) {
      _bufferingTimer?.cancel();
      _bufferingTimer = null;
      _bufferingGeneration = null;
      return;
    }
    if (_bufferingGeneration == _loadGeneration) return;
    final generation = _loadGeneration;
    _bufferingGeneration = generation;
    _bufferingTimer = Timer(bufferingTimeout, () {
      if (generation == _loadGeneration &&
          !_loading &&
          player.processingState == ProcessingState.buffering &&
          (shouldAutoAdvance?.call() ?? player.playing)) {
        onError?.call(TimeoutException('Audio buffering stalled'));
      }
    });
  }

  Duration? _positionOverride;

  MusicAudioHandler({
    AudioPlayer? player,
    this.bufferingTimeout = const Duration(seconds: 20),
  }) : player = player ?? AudioPlayer(useProxyForRequestHeaders: false) {
    this.player.playbackEventStream.listen((_) => publishState());
    this.player.playerStateStream.listen((state) {
      publishState();
      _watchBuffering(state.processingState, state.playing);
      _handleCompletion(state.processingState, state.playing);
    });
    this.player.errorStream.listen((error) => onError?.call(error));
  }

  void _handleCompletion(ProcessingState state, bool playing) {
    if (state != ProcessingState.completed) _completionHandled = false;
    if (state != ProcessingState.completed ||
        _loading ||
        _completionHandled ||
        !(shouldAutoAdvance?.call() ?? playing)) {
      return;
    }
    _completionHandled = true;
    final generation = _loadGeneration;
    scheduleMicrotask(() {
      if (generation != _loadGeneration ||
          _loading ||
          player.processingState != ProcessingState.completed ||
          !(shouldAutoAdvance?.call() ?? player.playing)) {
        return;
      }
      unawaited(
        Future<void>.sync(() => onNext?.call(true)).catchError((Object error) {
          Diagnostics.record('automatic-next', error);
          onError?.call(error);
        }),
      );
    });
  }

  Future<void> load(
    Uri uri,
    Map<String, String> headers, {
    Duration position = Duration.zero,
  }) async {
    final generation = ++_loadGeneration;
    _loading = true;
    _bufferingTimer?.cancel();
    _bufferingGeneration = null;
    try {
      await player
          .setAudioSource(
            AudioSource.uri(uri, headers: headers),
            initialPosition: position,
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () async {
              if (generation == _loadGeneration) await player.stop();
              throw TimeoutException('Audio source did not become ready');
            },
          );
    } on Object catch (error) {
      assert(() {
        debugPrint(
          'Audio source load failed: ${error is PlayerException ? error.code : error.runtimeType}',
        );
        return true;
      }());
      rethrow;
    } finally {
      if (generation == _loadGeneration) _loading = false;
    }
  }

  void start() {
    unawaited(
      player.play().catchError((Object error) {
        onError?.call(error);
      }),
    );
    _watchBuffering(player.processingState, true);
    _handleCompletion(player.processingState, true);
  }

  List<QueueEntry>? _publishedEntries;
  List<MediaItem> _publishedItems = const [];
  void publishQueue(QueueEngine engine, {Duration? position}) {
    _positionOverride = position;
    if (!identical(_publishedEntries, engine.entries)) {
      _publishedEntries = engine.entries;
      _publishedItems = List.unmodifiable(engine.entries.map(_item));
      queue.add(_publishedItems);
    }
    final currentIndex = engine.currentIndex;
    mediaItem.add(
      engine.current == null
          ? null
          : currentIndex >= 0
          ? _publishedItems[currentIndex]
          : _item(engine.current!),
    );
    canGoPrevious = engine.canPrevious;
    final index = engine.currentIndex;
    playbackState.add(
      playbackState.value.copyWith(
        queueIndex: index < 0 ? null : index,
        shuffleMode: engine.shuffled
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        repeatMode: switch (engine.repeat) {
          RepeatMode.off => AudioServiceRepeatMode.none,
          RepeatMode.all => AudioServiceRepeatMode.all,
          RepeatMode.one => AudioServiceRepeatMode.one,
        },
      ),
    );
    publishState();
  }

  MediaItem _item(QueueEntry entry) => MediaItem(
    id: entry.id,
    title: entry.track.title,
    artist: entry.track.subtitle,
    duration: entry.track.durationMs > 0
        ? Duration(milliseconds: entry.track.durationMs)
        : null,
  );

  void publishState() {
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          if (canGoPrevious) MediaControl.skipToPrevious,
          player.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        processingState: switch (player.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: player.playing,
        updatePosition: _positionOverride ?? player.position,
        bufferedPosition: player.bufferedPosition,
        speed: player.speed,
      ),
    );
  }

  @override
  Future<void> play() async => onPlay?.call();
  @override
  Future<void> pause() async => onPause?.call();
  @override
  Future<void> stop() async {
    await onStop?.call();
    await super.stop();
  }

  @override
  Future<void> skipToNext() async => onNext?.call(false);
  @override
  Future<void> skipToPrevious() async => onPrevious?.call();
  @override
  Future<void> skipToQueueItem(int index) async => onSelect?.call(index);
  @override
  Future<void> seek(Duration position) async => onSeek?.call(position);
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    onShuffle?.call(shuffleMode != AudioServiceShuffleMode.none);
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    onRepeat?.call(switch (repeatMode) {
      AudioServiceRepeatMode.one => RepeatMode.one,
      AudioServiceRepeatMode.all ||
      AudioServiceRepeatMode.group => RepeatMode.all,
      _ => RepeatMode.off,
    });
  }
}
