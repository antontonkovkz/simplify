import '../domain/library_item.dart';
import '../domain/queue_engine.dart';
import 'ports.dart';

abstract interface class PlaybackAudio {
  Duration get position;
  Future<void> pause();
  Future<void> stop();
  Future<void> load(Uri uri, Map<String, String> headers, {Duration position});
  void start();
  void publishQueue(QueueEngine engine, {Duration? position});
}

class RemotePlayback {
  const RemotePlayback(this.uri, this.headers, {this.playSessionId});
  final Uri uri;
  final Map<String, String> headers;
  final String? playSessionId;
}

abstract interface class PlaybackLibrary {
  Future<RemotePlayback> resolvePlayback(
    LibraryItem track, {
    Duration position,
  });
  Map<String, String> get headers;
  bool requiresConversion(LibraryItem track);
  Uri streamUri(LibraryItem track, {String? playSessionId});
  Future<void> releaseStream(String session);
  Future<SourceAvailability> availability(LibraryItem track);
}

abstract interface class PlaybackDownloads {
  bool contains(String id);
  String? localPath(String id);
  int? expectedBytes(String id);
  Future<void> invalidate(String id);
}

abstract interface class PlaybackPrefetch {
  void cancelPending();
  String? localPath(String id);
  Future<void> invalidate(String id);
}

/// Optional progressive cache capability; domain playback remains independent
/// of HTTP servers, files and the native audio implementation.
abstract interface class PlaybackStreamingCache {
  void activate(String id);
  Future<RemotePlayback> resolve(LibraryItem track);
  bool serves(String id);
}
