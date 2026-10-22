import '../application/playback_ports.dart';
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../domain/library_item.dart';
import 'jellyfin_library.dart';

/// A rolling, disposable cache, separate from user-requested offline downloads.
/// At most the current and next tracks are retained. URLs/tokens are never saved.
class TrackPreloader implements PlaybackPrefetch {
  TrackPreloader(
    this.directory,
    this.library, {
    http.Client Function()? clientFactory,
    this.maximumBytes = 256 * 1024 * 1024,
  }) : _clientFactory = clientFactory ?? http.Client.new;
  final Directory directory;
  final JellyfinLibrary library;
  final int maximumBytes;
  final http.Client Function() _clientFactory;
  final Map<String, String> _ready = {};
  http.Client? _client;
  String? _pending;
  int _generation = 0;
  bool _disposed = false;
  Future<void> _job = Future.value();
  Future<void> get settled => _job;
  @override
  String? localPath(String id) => _ready[id];

  @override
  void cancelPending() {
    _generation++;
    _client?.close();
    _client = null;
    _pending = null;
  }

  void prepare(LibraryItem? next, {String? currentId, required bool allowed}) {
    if (_disposed) return;
    final target = next != null && !next.isLocal ? next.id : null;
    final id = allowed ? target : null;
    final keep = {?currentId, ?target};
    for (final old in _ready.keys.toList()) {
      if (!keep.contains(old)) unawaited(invalidate(old));
    }
    if (_pending == id) return;
    _generation++;
    _client?.close();
    _client = null;
    _pending = id;
    if (id == null) return;
    if (_ready.containsKey(id)) {
      _pending = null;
      return;
    }
    final generation = _generation;
    final client = _clientFactory();
    _client = client;
    _job = _fetch(next!, client, generation);
  }

  Future<void> _fetch(
    LibraryItem track,
    http.Client client,
    int generation,
  ) async {
    File? part;
    IOSink? sink;
    try {
      await directory.create(recursive: true);
      await library.prepareDownload(track, transport: client);
      if (_disposed || generation != _generation) return;
      final response = await client
          .send(
            http.Request('GET', library.downloadUri(track))
              ..headers.addAll(library.headers),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 ||
          (response.contentLength ?? 0) > maximumBytes) {
        return;
      }
      final extension = library.requiresConversion(track)
          ? 'mp3'
          : track.fileName.split('.').last.toLowerCase();
      final safeId = Uri.encodeComponent(track.id);
      part = File('${directory.path}/$safeId-$generation.part');
      sink = part.openWrite();
      var bytes = 0;
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 25),
      )) {
        if (_disposed || generation != _generation) return;
        bytes += chunk.length;
        if (bytes > maximumBytes) return;
        sink.add(chunk);
        await sink.flush();
      }
      await sink.close();
      sink = null;
      if (_disposed ||
          generation != _generation ||
          bytes == 0 ||
          (response.contentLength != null && bytes != response.contentLength)) {
        return;
      }
      final file = await part.rename(
        '${directory.path}/$safeId-$generation.$extension',
      );
      part = null;
      _ready[track.id] = file.path;
    } on Object catch (_) {
      // Failure to prefetch never changes the queue or interrupts current audio.
    } finally {
      await sink?.close().catchError((Object _) {});
      if (part != null) {
        try {
          if (await part.exists()) await part.delete();
        } on Object catch (_) {}
      }
      client.close();
      if (generation == _generation) {
        _client = null;
        _pending = null;
      }
    }
  }

  @override
  Future<void> invalidate(String id) async {
    final path = _ready.remove(id);
    if (path != null) {
      try {
        await File(path).delete();
      } on Object catch (_) {}
    }
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _client?.close();
  }
}
