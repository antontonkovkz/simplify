import 'dart:async';
import 'dart:isolate';

import 'library_item.dart';

/// One worker owns a normalized index for the lifetime of a search screen.
/// Subsequent queries transfer only the query and matching occurrence indices.
class TrackSearchIndex {
  TrackSearchIndex(this.tracks);
  final List<LibraryItem> tracks;
  final _results = ReceivePort();
  final _ready = Completer<SendPort>();
  final _pending = <int, Completer<List<LibraryItem>>>{};
  Isolate? _worker;
  bool _disposed = false;
  int _serial = 0;
  List<List<String>>? _inlineIndex;
  Future<void>? _starting;

  Future<void> _start() async {
    _results.listen((dynamic value) {
      if (value is SendPort) {
        if (!_ready.isCompleted) _ready.complete(value);
      } else if (value is (int, List<int>)) {
        _pending
            .remove(value.$1)
            ?.complete(
              value.$2.map((index) => tracks[index]).toList(growable: false),
            );
      }
    });
    _worker = await Isolate.spawn(_searchWorker, (_results.sendPort, tracks));
    if (_disposed) _worker?.kill(priority: Isolate.immediate);
  }

  Future<List<LibraryItem>> find(String query) async {
    if (_disposed) return [];
    if (tracks.length <= 32) {
      final index = _inlineIndex ??= _normalize(tracks);
      final needle = query.trim().toLowerCase();
      return [
        for (var i = 0; i < index.length; i++)
          if (index[i].any((text) => text.contains(needle))) tracks[i],
      ];
    }
    await (_starting ??= _start());
    if (_disposed) return [];
    final port = await _ready.future;
    if (_disposed) return [];
    final id = _serial++;
    final result = Completer<List<LibraryItem>>();
    _pending[id] = result;
    port.send((id, query.trim().toLowerCase()));
    return result.future;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _worker?.kill(priority: Isolate.immediate);
    _results.close();
    for (final request in _pending.values) {
      request.complete([]);
    }
    _pending.clear();
    // Release callers waiting for a worker that was disposed before handshake.
    if (!_ready.isCompleted) {
      final unused = ReceivePort();
      _ready.complete(unused.sendPort);
      unused.close();
    }
  }
}

void _searchWorker((SendPort, List<LibraryItem>) input) {
  final index = _normalize(input.$2);
  final requests = ReceivePort();
  input.$1.send(requests.sendPort);
  requests.listen((dynamic value) {
    final request = value as (int, String);
    final matches = <int>[
      for (var i = 0; i < index.length; i++)
        if (index[i].any((text) => text.contains(request.$2))) i,
    ];
    input.$1.send((request.$1, matches));
  });
}

List<List<String>> _normalize(List<LibraryItem> tracks) => [
  for (final track in tracks)
    track.isTrack
        ? [
            track.fileName,
            track.name,
            track.artist,
          ].map((text) => text.toLowerCase()).toList(growable: false)
        : const <String>[],
];
