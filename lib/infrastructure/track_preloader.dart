import '../application/playback_ports.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import '../domain/library_item.dart';
import 'jellyfin_library.dart';
import 'progressive_audio_cache.dart';

/// One rolling cache for the current song and the reserved next song.
/// Promotion preserves a partial download and its stable local HTTP address.
class TrackPreloader implements PlaybackPrefetch, PlaybackStreamingCache {
  TrackPreloader(
    this.directory,
    this.library, {
    http.Client Function()? clientFactory,
    this.maximumBytes = 256 * 1024 * 1024,
    this.onChanged,
  }) : _clientFactory =
           clientFactory ??
           (() => IOClient(HttpClient()..maxConnectionsPerHost = 2));
  final Directory directory;
  final JellyfinLibrary library;
  final int maximumBytes;
  final void Function()? onChanged;
  final http.Client Function() _clientFactory;
  final _server = AudioCacheServer();
  final _slots = <String, _CacheSlot>{};
  String? _current, _next;
  bool _disposed = false, _allowed = true;
  int _serial = 0;
  final _filePrefix = Random.secure().nextInt(1 << 32).toRadixString(16);
  int revision = 0;
  Future<void> _job = Future.value();
  Future<void> get settled => _job;

  @override
  String? localPath(String id) {
    final cache = _slots[id]?.cache;
    return cache?.complete == true ? cache!.file.path : null;
  }

  @override
  bool serves(String id) =>
      _slots[id]?.cache != null && _slots[id]?.cache?.unsupported != true;

  @override
  void activate(String id) {
    _current = id;
    _next = null;
    _prune({id});
  }

  @override
  void cancelPending() {
    // Kept for stop/account-scope callers. Promotion uses activate instead.
    for (final id in _slots.keys.toList()) {
      if (id != _current && localPath(id) == null) unawaited(invalidate(id));
    }
  }

  @override
  Future<RemotePlayback> resolve(LibraryItem track) async {
    if (_disposed) throw StateError('Cache closed');
    final slot = _slots.putIfAbsent(track.id, () => _create(track));
    RemotePlayback source;
    try {
      source = await slot.source;
    } on Object {
      if (identical(_slots[track.id], slot)) await invalidate(track.id);
      rethrow;
    }
    if (slot.cancelled || _disposed) throw StateError('Cache closed');
    try {
      await slot.cache?.ready();
    } on Object {
      if (slot.cache?.unsupported != true) rethrow;
    }
    if (slot.cancelled || _disposed) throw StateError('Cache closed');
    if (slot.cache?.unsupported == true) {
      return RemotePlayback(source.uri, source.headers);
    }
    return slot.localUri == null
        ? RemotePlayback(source.uri, source.headers)
        : RemotePlayback(slot.localUri!, const {});
  }

  _CacheSlot _create(LibraryItem track) {
    final slot = _CacheSlot(_clientFactory());
    slot.source = () async {
      final source = await library.resolvePlayback(
        track,
        transport: slot.client,
      );
      slot.remote = source;
      if (slot.cancelled || _disposed) {
        await _release(slot);
        throw StateError('Cache closed');
      }
      // Segmented manifests are not byte-addressable audio files.
      if (source.uri.path.toLowerCase().endsWith('.m3u8') ||
          source.uri.path.toLowerCase().endsWith('.mpd')) {
        return source;
      }
      final suffix = library.requiresConversion(track)
          ? 'mp3'
          : track.fileName
                .split('.')
                .last
                .replaceAll(RegExp('[^a-zA-Z0-9]'), '');
      final cache = ProgressiveAudioCache(
        file: File(
          '${directory.path}/$_filePrefix-${++_serial}.${suffix.isEmpty ? 'audio' : suffix}',
        ),
        uri: source.uri,
        headers: source.headers,
        client: slot.client,
        maximumBytes: maximumBytes,
        onComplete: () {
          if (_disposed || slot.cancelled) return;
          revision++;
          onChanged?.call();
        },
      );
      slot.cache = cache;
      slot.localUri = await _server.add(cache);
      if (slot.cancelled || _disposed) {
        await cache.close();
        throw StateError('Cache closed');
      }
      cache.setNetworkAllowed(_allowed);
      cache.start();
      return source;
    }();
    // Speculative jobs and cancelled operations must never leak async errors.
    unawaited(slot.source.then<void>((_) {}, onError: (Object _) {}));
    return slot;
  }

  void prepare(LibraryItem? next, {String? currentId, required bool allowed}) {
    if (_disposed) return;
    _current = currentId;
    _next = next != null && !next.isLocal ? next.id : null;
    _prune({?currentId, ?_next});
    _allowed = allowed;
    for (final slot in _slots.values) {
      slot.cache?.setNetworkAllowed(allowed);
    }
    if (!allowed || next == null || _next == null) return;
    // Give the current full-file download priority, then warm the successor.
    final current = _slots[currentId];
    final target = next;
    _job = () async {
      try {
        if (current != null) {
          await current.source;
          await current.cache?.settled;
        }
        if (_disposed || !_allowed || _next != target.id) return;
        await resolve(target);
        await _slots[target.id]?.cache?.settled;
      } on Object {
        /* Speculation must not change playback or queue state. */
      }
    }();
  }

  void _prune(Set<String> keep) {
    for (final id in _slots.keys.toList()) {
      if (!keep.contains(id)) unawaited(invalidate(id));
    }
  }

  Future<void> _release(_CacheSlot slot) async {
    final session = slot.remote?.playSessionId;
    slot.remote = null;
    if (session != null) await library.releaseStream(session);
  }

  @override
  Future<void> invalidate(String id) async {
    final slot = _slots.remove(id);
    if (slot == null) return;
    slot.cancelled = true;
    slot.client.close();
    final cache = slot.cache;
    if (cache != null) {
      _server.remove(cache);
      try {
        await cache.close();
      } on Object {
        /* Disposable cache cleanup. */
      }
    }
    await _release(slot);
    revision++;
  }

  Future<void> close() async {
    _disposed = true;
    await _server.close();
    await Future.wait(_slots.keys.toList().map(invalidate));
  }

  void dispose() => unawaited(close());
}

class _CacheSlot {
  _CacheSlot(this.client);
  final http.Client client;
  late Future<RemotePlayback> source;
  RemotePlayback? remote;
  ProgressiveAudioCache? cache;
  Uri? localUri;
  bool cancelled = false;
}
