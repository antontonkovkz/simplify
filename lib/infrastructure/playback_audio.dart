import '../application/playback_ports.dart';
import '../domain/queue_engine.dart';
import 'music_audio_handler.dart';

/// System command callbacks and source transport deliberately use different
/// methods: calling handler.pause() here would recurse into the app command.
class PlaybackAudioAdapter implements PlaybackAudio {
  PlaybackAudioAdapter(this.handler);
  final MusicAudioHandler handler;
  @override
  Duration get position => handler.player.position;
  @override
  Future<void> pause() => handler.player.pause();
  @override
  Future<void> stop() => handler.player.stop();
  @override
  Future<void> load(
    Uri uri,
    Map<String, String> headers, {
    Duration position = Duration.zero,
  }) => handler.load(uri, headers, position: position);
  @override
  void start() => handler.start();
  @override
  void publishQueue(QueueEngine engine, {Duration? position}) =>
      handler.publishQueue(engine, position: position);
}
