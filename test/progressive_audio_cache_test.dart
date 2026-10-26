import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:simplefy/infrastructure/progressive_audio_cache.dart';

void main() {
  late Directory directory;
  late HttpServer origin;
  late AudioCacheServer proxy;
  ProgressiveAudioCache? cache;
  final bytes = List.generate(16384, (i) => i % 251);
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('simplefy-progressive-');
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    proxy = AudioCacheServer();
  });
  tearDown(() async {
    await proxy.close();
    await cache?.close();
    cache = null;
    await origin.close(force: true);
    await directory.delete(recursive: true);
  });
  Future<Uri> create() async {
    cache = ProgressiveAudioCache(
      file: File('${directory.path}/audio.mp3'),
      uri: Uri.parse('http://127.0.0.1:${origin.port}/audio'),
      headers: const {'Authorization': 'fixture'},
      client: http.Client(),
      maximumBytes: 32768,
      retryDelay: const Duration(milliseconds: 5),
      timeout: const Duration(seconds: 2),
    );
    cache!.start();
    return proxy.add(cache!);
  }

  Future<void> prefix() async {
    for (var i = 0; i < 200 && cache!.received < 1024; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(cache!.received, greaterThanOrEqualTo(1024));
  }

  void headers(HttpResponse response) {
    response.bufferOutput = false;
    response.headers.set('Content-Type', 'audio/mpeg');
    response.headers.set('ETag', '"fixture-v1"');
    response.headers.set('Accept-Ranges', 'bytes');
  }

  test(
    'plays prefix before EOF; same URL serves complete file with origin offline',
    () async {
      final finish = Completer<void>();
      var requests = 0;
      origin.listen((request) async {
        requests++;
        expect(request.headers.value('Authorization'), 'fixture');
        headers(request.response);
        request.response.contentLength = bytes.length;
        request.response.add(bytes.sublist(0, 1024));
        await request.response.flush();
        await finish.future;
        request.response.add(bytes.sublist(1024));
        await request.response.close();
      });
      final uri = await create();
      await prefix();
      final first = await http.get(uri, headers: {'Range': 'bytes=0-31'});
      expect(first.statusCode, 206);
      expect(first.bodyBytes, bytes.sublist(0, 32));
      expect(cache!.complete, false);
      final stream = http.get(uri);
      finish.complete();
      expect((await stream).bodyBytes, bytes);
      await cache!.settled;
      expect(cache!.complete, true);
      await origin.close(force: true);
      expect((await http.get(uri)).bodyBytes, bytes);
      expect(
        (await http.get(uri, headers: {'Range': 'bytes=-20'})).bodyBytes,
        bytes.sublist(bytes.length - 20),
      );
      expect(
        (await http.get(uri, headers: {'Range': 'bytes=99999-'})).statusCode,
        416,
      );
      expect(requests, 1);
    },
  );

  test(
    'forward seek fetches validated range without cancelling full download',
    () async {
      final finish = Completer<void>();
      final ranges = <String?>[];
      origin.listen((request) async {
        final range = request.headers.value('Range');
        ranges.add(range);
        headers(request.response);
        if (range != null) {
          expect(range, 'bytes=12000-12031');
          expect(request.headers.value('If-Range'), '"fixture-v1"');
          request.response.statusCode = 206;
          request.response.headers.set(
            'Content-Range',
            'bytes 12000-12031/${bytes.length}',
          );
          request.response.contentLength = 32;
          request.response.add(bytes.sublist(12000, 12032));
        } else {
          request.response.contentLength = bytes.length;
          request.response.add(bytes.sublist(0, 1024));
          await request.response.flush();
          await finish.future;
          request.response.add(bytes.sublist(1024));
        }
        await request.response.close();
      });
      final uri = await create();
      await prefix();
      final seek = await http.get(uri, headers: {'Range': 'bytes=12000-12031'});
      expect(seek.bodyBytes, bytes.sublist(12000, 12032));
      expect(cache!.complete, false);
      finish.complete();
      await cache!.settled;
      expect((await http.get(uri)).bodyBytes, bytes);
      expect(ranges, [null, 'bytes=12000-12031']);
    },
  );

  test('forward seek uses Last-Modified when ETag is weak', () async {
    final finish = Completer<void>();
    final ranges = <String?>[];
    origin.listen((request) async {
      final range = request.headers.value('Range');
      ranges.add(range);
      headers(request.response);
      request.response.headers.set('ETag', 'W/"fixture-v1"');
      request.response.headers.set(
        'Last-Modified',
        'Mon, 26 Oct 2026 08:00:00 GMT',
      );
      if (range != null) {
        expect(range, 'bytes=12000-12031');
        expect(
          request.headers.value('If-Range'),
          'Mon, 26 Oct 2026 08:00:00 GMT',
        );
        request.response.statusCode = 206;
        request.response.headers.set(
          'Content-Range',
          'bytes 12000-12031/${bytes.length}',
        );
        request.response.contentLength = 32;
        request.response.add(bytes.sublist(12000, 12032));
      } else {
        request.response.contentLength = bytes.length;
        request.response.add(bytes.sublist(0, 1024));
        await request.response.flush();
        await finish.future;
        request.response.add(bytes.sublist(1024));
      }
      await request.response.close();
    });
    final uri = await create();
    await prefix();
    final seek = await http.get(uri, headers: {'Range': 'bytes=12000-12031'});
    expect(seek.bodyBytes, bytes.sublist(12000, 12032));
    expect(cache!.complete, false);
    finish.complete();
    await cache!.settled;
    expect((await http.get(uri)).bodyBytes, bytes);
    expect(ranges, [null, 'bytes=12000-12031']);
  });

  test(
    'transport dropout resumes with If-Range and preserves connected reader',
    () async {
      final ranges = <String?>[];
      origin.listen((request) async {
        final range = request.headers.value('Range');
        ranges.add(range);
        headers(request.response);
        if (range == null) {
          final socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.write(
            'HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: ${bytes.length}\r\nETag: "fixture-v1"\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n',
          );
          socket.add(bytes.sublist(0, 1024));
          await socket.flush();
          await socket.close();
        } else {
          expect(range, 'bytes=1024-');
          request.response.statusCode = 206;
          request.response.headers.set(
            'Content-Range',
            'bytes 1024-${bytes.length - 1}/${bytes.length}',
          );
          request.response.contentLength = bytes.length - 1024;
          request.response.add(bytes.sublist(1024));
          await request.response.close();
        }
      });
      final uri = await create();
      expect((await http.get(uri)).bodyBytes, bytes);
      expect(cache!.complete, true);
      expect(ranges, [null, 'bytes=1024-']);
    },
  );

  test(
    'unknown-length transcode streams immediately and becomes seekable at EOF',
    () async {
      final finish = Completer<void>();
      origin.listen((request) async {
        request.response.bufferOutput = false;
        request.response.headers.set('Content-Type', 'audio/mpeg');
        request.response.add(bytes.sublist(0, 1024));
        await request.response.flush();
        await finish.future;
        request.response.add(bytes.sublist(1024));
        await request.response.close();
      });
      final uri = await create();
      await prefix();
      expect(cache!.length, null);
      final client = http.Client();
      final response = await client.send(http.Request('GET', uri));
      final reader = StreamIterator(response.stream);
      expect(await reader.moveNext(), true);
      expect(reader.current, bytes.sublist(0, 1024));
      finish.complete();
      await reader.cancel();
      client.close();
      await cache!.settled;
      expect(cache!.length, bytes.length);
      expect(
        (await http.get(uri, headers: {'Range': 'bytes=3-9'})).bodyBytes,
        bytes.sublist(3, 10),
      );
    },
  );

  test(
    'network policy suspends download but preserves prefix, then resumes',
    () async {
      final first = Completer<void>();
      origin.listen((request) async {
        headers(request.response);
        final range = request.headers.value('Range');
        if (range == null) {
          request.response.contentLength = bytes.length;
          request.response.add(bytes.sublist(0, 1024));
          await request.response.flush();
          await first.future;
          try {
            await request.response.close();
          } on Object {
            /* Client cancelled. */
          }
        } else {
          request.response.statusCode = 206;
          request.response.headers.set(
            'Content-Range',
            'bytes 1024-${bytes.length - 1}/${bytes.length}',
          );
          request.response.contentLength = bytes.length - 1024;
          request.response.add(bytes.sublist(1024));
          await request.response.close();
        }
      });
      final uri = await create();
      await prefix();
      cache!.setNetworkAllowed(false);
      expect(
        (await http.get(uri, headers: {'Range': 'bytes=0-31'})).bodyBytes,
        bytes.sublist(0, 32),
      );
      expect(cache!.complete, false);
      cache!.setNetworkAllowed(true);
      await cache!.settled;
      first.complete();
      expect(cache!.complete, true);
      expect((await http.get(uri)).bodyBytes, bytes);
    },
  );
  for (final changed in [false, true]) {
    test(
      'restart without validators verifies existing bytes (changed=$changed)',
      () async {
        var requests = 0;
        origin.listen((request) async {
          requests++;
          if (requests == 1) {
            final socket = await request.response.detachSocket(
              writeHeaders: false,
            );
            socket.write(
              'HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nContent-Length: ${bytes.length}\r\nConnection: close\r\n\r\n',
            );
            socket.add(bytes.sublist(0, 1024));
            await socket.flush();
            await socket.close();
          } else {
            expect(request.headers.value('Range'), isNull);
            request.response.contentLength = bytes.length;
            request.response.add(
              changed ? List.filled(bytes.length, 255) : bytes,
            );
            await request.response.close();
          }
        });
        await create();
        await cache!.settled;
        expect(cache!.complete, !changed);
        expect(cache!.unsupported, changed);
        expect(
          await cache!.file.readAsBytes(),
          changed ? bytes.sublist(0, 1024) : bytes,
        );
        expect(requests, 2);
      },
    );
  }
  test(
    'closed loopback listener is rebound without dropping cached tracks',
    () async {
      await proxy.close();
      HttpServer? listener;
      proxy = AudioCacheServer(
        bind: () async {
          listener = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          return listener!;
        },
      );
      origin.listen((request) async {
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
      final old = await create();
      expect((await http.get(old)).bodyBytes, bytes);
      await listener!.close(force: true);
      final recovered = await proxy.add(cache!);
      expect((await http.get(recovered)).bodyBytes, bytes);
      expect(await proxy.add(cache!), recovered);
      expect(cache!.complete, true);
    },
  );
}
