import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:http/http.dart' as http;

/// A growing file shared by speculative downloading and native HTTP readers.
/// Only the writer appends; readers see bytes after writeFrom has completed.
class ProgressiveAudioCache {
  ProgressiveAudioCache({
    required this.file,
    required this.uri,
    required this.headers,
    required this.client,
    required this.maximumBytes,
    this.onComplete,
    this.retryDelay = const Duration(seconds: 1),
    this.timeout = const Duration(seconds: 15),
  });
  final File file;
  final Uri uri;
  final Map<String, String> headers;
  final http.Client client;
  final int maximumBytes;
  final void Function()? onComplete;
  final Duration retryDelay, timeout;
  int received = 0;
  int? length;
  String contentType = 'application/octet-stream';
  String? _validator;
  bool _ranges = false, complete = false, disposed = false;
  bool unsupported = false;
  Object? failure;
  bool _allowed = true;
  Completer<void>? _abort;
  final _requests = <Completer<void>>{};
  void setNetworkAllowed(bool value) {
    _allowed = value;
    if (!value) {
      for (final request in _requests) {
        if (!request.isCompleted) request.complete();
      }
    }
    _pulse();
    if (value) start();
  }

  Completer<void> _changed = Completer<void>();
  final _metadata = Completer<void>();
  Future<void>? _job;
  Future<void> get settled => _job ?? Future.value();

  void _pulse() {
    final previous = _changed;
    _changed = Completer<void>();
    previous.complete();
  }

  void start() {
    if (_job != null || complete || disposed || unsupported || !_allowed) {
      return;
    }
    failure = null;
    _job = _download().whenComplete(() => _job = null);
  }

  Future<void> ready() async {
    start();
    await _metadata.future.timeout(timeout);
    if (failure != null) throw failure!;
    if (disposed) throw const HttpException('Cache closed');
  }

  Future<http.StreamedResponse> _get({
    String? range,
    bool downloading = false,
  }) async {
    if (disposed) throw const HttpException('Cache closed');
    if (!_allowed) throw const HttpException('Network disabled');
    final abort = Completer<void>();
    _requests.add(abort);
    if (downloading) _abort = abort;
    final request =
        http.AbortableRequest('GET', uri, abortTrigger: abort.future)
          ..followRedirects = false
          ..headers.addAll(headers)
          ..headers['Accept-Encoding'] = 'identity';
    if (range != null) {
      request.headers['Range'] = range;
      if (_validator != null) request.headers['If-Range'] = _validator!;
    }
    try {
      final response = await client
          .send(request)
          .timeout(
            timeout,
            onTimeout: () {
              if (!abort.isCompleted) abort.complete();
              throw TimeoutException('Audio headers timed out');
            },
          );
      return http.StreamedResponse(
        _responseBytes(response.stream, abort),
        response.statusCode,
        contentLength: response.contentLength,
        headers: response.headers,
      );
    } on Object {
      _requests.remove(abort);
      rethrow;
    }
  }

  Stream<List<int>> _responseBytes(
    Stream<List<int>> input,
    Completer<void> abort,
  ) async* {
    try {
      await for (final bytes in input) {
        yield bytes;
      }
    } finally {
      _requests.remove(abort);
      if (!abort.isCompleted) abort.complete();
    }
  }

  Future<void> _download() async {
    RandomAccessFile? writer;
    try {
      await file.parent.create(recursive: true);
      writer = await file.open(mode: FileMode.append);
      for (var attempt = 0; attempt < 3 && !disposed; attempt++) {
        try {
          // Without a validator restart and compare the existing prefix instead
          // of splicing potentially different representations after a dropout.
          final offset = _ranges && _validator != null ? received : 0;
          final response = await _get(
            range: offset > 0 ? 'bytes=$offset-' : null,
            downloading: true,
          );
          if (disposed) return;
          if (!_allowed) throw const HttpException('Network disabled');
          if (response.statusCode != 200 && response.statusCode != 206) {
            if (response.statusCode >= 300 && response.statusCode < 400) {
              unsupported = true;
            }
            throw HttpException('Audio HTTP ${response.statusCode}');
          }
          final partial = response.statusCode == 206;
          if (partial) {
            final range = _parseContentRange(response.headers['content-range']);
            if (range == null ||
                range.$1 != offset ||
                (length != null && range.$3 != length)) {
              throw const HttpException('Invalid audio range');
            }
            length = range.$3;
          } else {
            final size = response.contentLength;
            if (received > 0 &&
                length != null &&
                size != null &&
                size != length) {
              unsupported = true;
              throw const HttpException('Audio representation changed');
            }
            length = size;
          }
          if (length != null && length! > maximumBytes) {
            unsupported = true;
            throw const HttpException('Audio exceeds temporary cache limit');
          }
          final validator = _responseValidator(response.headers);
          if (_validator != null && validator != _validator && received > 0) {
            unsupported = true;
            throw const HttpException('Audio representation changed');
          }
          _validator = validator;
          _ranges = response.headers['accept-ranges'] == 'bytes' || partial;
          contentType = response.headers['content-type'] ?? contentType;
          if (!_metadata.isCompleted) _metadata.complete();
          var cursor = partial ? offset : 0;
          await for (final chunk in response.stream.timeout(timeout)) {
            if (disposed) return;
            if (!_allowed) throw const HttpException('Network disabled');
            if (cursor + chunk.length > maximumBytes) {
              unsupported = true;
              throw const HttpException('Audio exceeds temporary cache limit');
            }
            final overlap = min(chunk.length, max(0, received - cursor));
            if (overlap > 0) {
              final old = await file.open();
              try {
                await old.setPosition(cursor);
                final bytes = await old.read(overlap);
                if (bytes.length != overlap) {
                  throw const HttpException('Cache truncated');
                }
                for (var i = 0; i < overlap; i++) {
                  if (bytes[i] != chunk[i]) {
                    unsupported = true;
                    throw const HttpException('Audio representation changed');
                  }
                }
              } finally {
                await old.close();
              }
            }
            if (overlap < chunk.length) {
              await writer.writeFrom(chunk, overlap);
              received += chunk.length - overlap;
              _pulse();
            }
            cursor += chunk.length;
          }
          if (length != null && cursor != length) {
            throw const HttpException('Incomplete audio response');
          }
          length = received;
          if (received == 0) throw const HttpException('Empty audio response');
          await writer.flush();
          complete = true;
          failure = null;
          _pulse();
          onComplete?.call();
          return;
        } on Object catch (error) {
          if (_abort?.isCompleted == false) _abort!.complete();
          if (disposed) return;
          if (!_allowed) {
            while (!_allowed && !disposed) {
              await _changed.future;
            }
            attempt--;
            continue;
          }
          if (attempt == 2 || unsupported) {
            failure = error;
            return;
          }
          await Future<void>.delayed(retryDelay * (attempt + 1));
        }
      }
    } on Object catch (error) {
      failure = error;
    } finally {
      await writer?.close();
      if (received == 0 && await file.exists()) await file.delete();
      if (!_metadata.isCompleted) _metadata.complete();
      _pulse();
    }
  }

  /// A forward seek can read a remote range while the full download continues.
  /// Cached-prefix requests never make a second network request.
  Stream<List<int>> read(int start, int? end) async* {
    if (start > received && !complete && _ranges && _validator != null) {
      final response = await _get(
        range: 'bytes=$start-${end == null ? '' : end - 1}',
      );
      final range = _parseContentRange(response.headers['content-range']);
      final validator = _responseValidator(response.headers);
      if (response.statusCode == 200 && validator == _validator) {
        // A server may ignore Range despite advertising it. Keep using the
        // original growing file instead of starting playback at byte zero.
        _ranges = false;
        await response.stream.listen((_) {}).cancel();
      } else {
        if (response.statusCode != 206 ||
            range == null ||
            range.$1 != start ||
            range.$3 != length ||
            validator != _validator ||
            (end != null && range.$2 + 1 != end)) {
          await response.stream.listen((_) {}).cancel();
          throw const HttpException('Invalid seek range');
        }
        var count = 0;
        await for (final bytes in response.stream.timeout(timeout)) {
          if (disposed) throw const HttpException('Cache closed');
          count += bytes.length;
          if (count > range.$2 - start + 1) {
            throw const HttpException('Excess seek bytes');
          }
          yield bytes;
        }
        if (count != range.$2 - start + 1) {
          throw const HttpException('Incomplete seek range');
        }
        return;
      }
    }
    var cursor = start;
    final reader = await file.open();
    try {
      while (!disposed) {
        final signal = _changed.future;
        final available = min(received, end ?? received);
        if (cursor < available) {
          await reader.setPosition(cursor);
          final bytes = await reader.read(min(64 * 1024, available - cursor));
          if (bytes.isEmpty) throw const HttpException('Cache truncated');
          cursor += bytes.length;
          yield bytes;
          continue;
        }
        if ((end != null && cursor >= end) || complete) return;
        if (failure != null) throw failure!;
        await signal.timeout(timeout * 3);
      }
      throw const HttpException('Cache closed');
    } finally {
      await reader.close();
    }
  }

  Future<void> close() async {
    disposed = true;
    for (final request in _requests) {
      if (!request.isCompleted) request.complete();
    }
    client.close();
    _pulse();
    await settled;
    if (await file.exists()) await file.delete();
  }
}

String? _responseValidator(Map<String, String> headers) {
  final tag = headers['etag'];
  return tag != null && !tag.startsWith('W/') ? tag : headers['last-modified'];
}

(int, int, int)? _parseContentRange(String? text) {
  final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(text ?? '');
  if (match == null) return null;
  final start = int.parse(match[1]!);
  final end = int.parse(match[2]!);
  final total = int.parse(match[3]!);
  return start <= end && end < total ? (start, end, total) : null;
}

/// Loopback only; opaque paths, no server credentials in URLs or files.
class AudioCacheServer {
  HttpServer? _server;
  Future<HttpServer>? _opening;
  final _entries = <String, ProgressiveAudioCache>{};
  final _random = Random.secure();
  bool _closed = false;

  Future<Uri> add(ProgressiveAudioCache entry) async {
    final server = await (_opening ??=
        HttpServer.bind(InternetAddress.loopbackIPv4, 0).then((server) {
          if (_closed) {
            unawaited(server.close(force: true));
            throw StateError('Cache closed');
          }
          _server = server;
          server.listen((request) => unawaited(_serve(request)));
          return server;
        }));
    final key = List.generate(
      24,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final path = '$key.${entry.file.path.split('.').last}';
    _entries[path] = entry;
    return Uri.parse('http://127.0.0.1:${server.port}/$path');
  }

  void remove(ProgressiveAudioCache entry) =>
      _entries.removeWhere((_, value) => identical(value, entry));

  Future<void> _serve(HttpRequest request) async {
    final response = request.response;
    response.bufferOutput = false;
    try {
      final entry = _entries[request.uri.path.substring(1)];
      if (entry == null ||
          (request.method != 'GET' && request.method != 'HEAD')) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      await entry.ready();
      var start = 0;
      int? end = entry.length;
      final rawRange = request.headers.value(HttpHeaders.rangeHeader);
      var partial = false;
      if (rawRange != null && entry.length != null) {
        final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(rawRange);
        if (match == null || (match[1]!.isEmpty && match[2]!.isEmpty)) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          return;
        }
        if (match[1]!.isEmpty) {
          start = max(0, entry.length! - int.parse(match[2]!));
        } else {
          start = int.parse(match[1]!);
          if (match[2]!.isNotEmpty) {
            end = min(entry.length!, int.parse(match[2]!) + 1);
          }
        }
        if (start >= end!) {
          response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          response.headers.set('Content-Range', 'bytes */${entry.length}');
          return;
        }
        partial = true;
      }
      response.headers.set(HttpHeaders.contentTypeHeader, entry.contentType);
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.headers.set(
        HttpHeaders.acceptRangesHeader,
        entry.length == null ? 'none' : 'bytes',
      );
      if (end != null) response.contentLength = end - start;
      if (partial) {
        response.statusCode = HttpStatus.partialContent;
        response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes $start-${end! - 1}/${entry.length}',
        );
      }
      if (request.method != 'HEAD') {
        await response.addStream(entry.read(start, end));
      }
    } on Object {
      // A failed response must be truncated, never padded with invalid audio.
      try {
        response.statusCode = HttpStatus.serviceUnavailable;
      } on Object {
        /* Headers already sent. */
      }
    } finally {
      try {
        await response.close();
      } on Object {
        /* Player cancelled a range. */
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    _entries.clear();
    await _server?.close(force: true);
  }
}
