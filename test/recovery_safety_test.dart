import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simplefy/application/app_controller.dart';
import 'package:simplefy/application/diagnostics.dart';
import 'package:simplefy/application/playback_coordinator.dart';
import 'package:simplefy/application/playback_ports.dart';
import 'package:simplefy/application/playback_recovery.dart';
import 'package:simplefy/application/ports.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/domain/queue_engine.dart';
import 'package:simplefy/infrastructure/jellyfin_library.dart';
import 'package:simplefy/infrastructure/local_store.dart';
import 'playlist_edit_controller_test.dart' show IdleAudio;

const song = LibraryItem(id: 'song', name: 'Song', kind: ItemKind.track);

class BrokenStore extends LocalStore {
  BrokenStore(super.directory);
  @override
  Future<Map<String, dynamic>> read(String key) async =>
      throw const FileSystemException('fixture');
}

class SourceAudio implements PlaybackAudio {
  Object? failure;
  final loaded = <Uri>[];
  @override
  Duration position = const Duration(seconds: 12);
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> load(
    Uri uri,
    Map<String, String> headers, {
    Duration position = Duration.zero,
  }) async {
    loaded.add(uri);
    if (failure != null) throw failure!;
  }

  @override
  void start() {}
  @override
  void publishQueue(QueueEngine engine, {Duration? position}) {}
}

class LocalDownloads implements PlaybackDownloads {
  LocalDownloads(this.path);
  String? path;
  int invalidations = 0;
  @override
  bool contains(String id) => path != null;
  @override
  String? localPath(String id) => path;
  @override
  int? expectedBytes(String id) => 4;
  @override
  Future<void> invalidate(String id) async {
    invalidations++;
    path = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'initialize always leaves the loading state even when the first read fails',
    () async {
      final app = AppController(BrokenStore(Directory.systemTemp), IdleAudio());
      try {
        await app.initialize();
        expect(app.initialized, true);
        expect(app.loggedIn, false);
        expect(Diagnostics.events.last.operation, 'initialize');
      } finally {
        app.dispose();
      }
    },
  );
  test(
    'malformed and future queue fields restore without losing valid occurrences',
    () {
      final original = QueueEngine()..replace([song, song]);
      final json = original.toJson();
      json['repeat'] = 'future-mode';
      json['shuffled'] = {'not': 'a boolean'};
      json['history'] = [42, original.current!.id, 'deleted'];
      json['entries'] = <Object?>[
        ...(json['entries'] as List),
        null,
        {
          'id': 'bad',
          'track': {'id': '../bad'},
        },
      ];
      final restored = QueueEngine()..restore(json);
      expect(restored.entries.length, 2);
      expect(restored.repeat, RepeatMode.off);
      expect(restored.shuffled, false);
      expect(restored.currentIndex, 0);
      for (final value in [null, 1, 'bad', {}]) {
        restored.restore({
          'entries': value,
          'current': value,
          'history': value,
          'visited': value,
          'repeat': value,
        });
        expect(restored.entries, isEmpty);
      }
    },
  );
  test(
    'repeat history stays bounded and reserved shuffle successors stay stable',
    () {
      final queue = QueueEngine(random: Random(1))..replace([song, song]);
      queue.repeat = RepeatMode.all;
      for (var i = 0; i < 5000; i++) {
        queue.next();
      }
      expect(
        (queue.toJson()['history'] as List).length,
        QueueEngine.maxHistory,
      );
      queue.shuffled = true;
      final preview = queue.previewNext();
      for (var i = 0; i < 50; i++) {
        expect(queue.previewNext(), same(preview));
      }
      expect(queue.next(), same(preview));
    },
  );
  test(
    'unsupported schema and repeated corruption retain distinct originals',
    () async {
      final dir = await Directory.systemTemp.createTemp('simplefy-recovery-');
      try {
        final store = LocalStore(dir);
        final file = File('${dir.path}/state.json');
        await file.writeAsString('{"schemaVersion":999,"data":{}}');
        expect(await store.read('state'), isEmpty);
        await file.writeAsString('second damaged snapshot');
        expect(await store.read('state'), isEmpty);
        final backups = await dir
            .list()
            .where((f) => f.path.endsWith('.damaged'))
            .toList();
        expect(backups.length, 2);
        final contents = await Future.wait(
          backups.map((f) => File(f.path).readAsString()),
        );
        expect(
          contents,
          containsAll([
            '{"schemaVersion":999,"data":{}}',
            'second damaged snapshot',
          ]),
        );
        final ids = await Future.wait(
          List.generate(20, (_) => store.installationId()),
        );
        expect(ids.toSet().length, 1);
        expect((await store.read('installation'))['deviceId'], ids.first);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'decoder timeouts preserve valid downloaded bytes and bound retries',
    () async {
      final dir = await Directory.systemTemp.createTemp('simplefy-playback-');
      final file = File('${dir.path}/song.audio');
      await file.writeAsBytes([1, 2, 3, 4]);
      final audio = SourceAudio()..failure = TimeoutException('fixture');
      final downloads = LocalDownloads(file.path);
      final queue = QueueEngine()..replace([song]);
      Object? status;
      late PlaybackCoordinator coordinator;
      coordinator = PlaybackCoordinator(
        queue: queue,
        audio: audio,
        libraryProvider: () => null,
        downloadsProvider: () => downloads,
        prefetchProvider: () => null,
        importedPath: (_) => null,
        streamAllowed: () => false,
        changed: () {},
        notifyListeners: () {},
        message: (_) {},
        statusReader: () => status,
        statusWriter: (value) => status = value,
        next: (_) async {},
        pause: () async {},
        resume: () async {},
        applyNormalization: (_) async {},
        reportUnavailable: (_) {},
        resetSkipped: () {},
      )..wantsPlayback = true;
      try {
        await coordinator.start(queue.current);
        expect(downloads.invalidations, 0);
        expect(await file.readAsBytes(), [1, 2, 3, 4]);
        expect(coordinator.waitingForNetwork, true);
        coordinator.retryTimer?.cancel();
        await coordinator.start(queue.current);
        coordinator.retryTimer?.cancel();
        await coordinator.start(queue.current);
        expect(coordinator.wantsPlayback, false);
        expect(downloads.invalidations, 0);
        expect(await file.length(), 4);
        expect(await inspectAudioFile(file.path, 4), LocalFileState.healthy);
        expect(await inspectAudioFile(file.path, 5), LocalFileState.changed);
        await file.writeAsBytes([]);
        expect(await inspectAudioFile(file.path, null), LocalFileState.empty);
        await file.delete();
        expect(await inspectAudioFile(file.path, null), LocalFileState.missing);
      } finally {
        coordinator.retryTimer?.cancel();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'login validates response shapes, maps timeout/TLS and never exposes server content',
    () async {
      for (final body in [
        '<html>private server detail</html>',
        '{}',
        '{"User":{},"AccessToken":"x"}',
        '{"User":{"Id":"../bad"},"AccessToken":"x"}',
      ]) {
        final client = MockClient((_) async => http.Response(body, 200));
        await expectLater(
          JellyfinLibrary.login(
            'https://example.com',
            'fixture',
            'fixture',
            client: client,
          ),
          throwsA(isA<AppFailure>()),
        );
        client.close();
      }
      for (final error in [
        const HandshakeException('private'),
        TimeoutException('private'),
      ]) {
        final client = MockClient((_) async => throw error);
        try {
          await JellyfinLibrary.login(
            'https://example.com',
            'fixture',
            'fixture',
            client: client,
          );
          fail('accepted failed login');
        } on AppFailure catch (failure) {
          expect(failure.message, isNot(contains('private')));
        }
        client.close();
      }
      final client = MockClient(
        (r) async => http.Response(
          jsonEncode({
            'User': {'Id': 'u'},
            'AccessToken': 'fixture',
          }),
          200,
        ),
      );
      expect(
        (await JellyfinLibrary.login(
          'example.com/',
          'fixture',
          'fixture',
          client: client,
        )).userId,
        'u',
      );
      client.close();
      expect(
        AppController.friendly(const FormatException('private-token')),
        isNot(contains('private-token')),
      );
    },
  );
  test(
    'server IDs are rejected before requests or file path construction',
    () async {
      var calls = 0;
      final api = JellyfinLibrary(
        const ServerSession('https://example.com', 'u', 'fixture', 'u'),
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      try {
        for (final id in ['../other', 'a/b', 'a?x=y', '%2f', 'local:fake']) {
          expect(
            () => JellyfinLibrary.parse({
              'Id': id,
              'Name': 'Bad',
              'Type': 'Audio',
            }),
            throwsFormatException,
          );
          await expectLater(api.playlistIds(id), throwsFormatException);
          expect(
            () => api.downloadUri(
              LibraryItem(id: id, name: 'Bad', kind: ItemKind.track),
            ),
            throwsFormatException,
          );
        }
        expect(calls, 0);
      } finally {
        api.close();
      }
    },
  );
  test(
    'forbidden logout is not reported as successful token revocation',
    () async {
      final api = JellyfinLibrary(
        const ServerSession('https://example.com', 'u', 'fixture', 'u'),
        client: MockClient((_) async => http.Response('', 403)),
      );
      try {
        await expectLater(
          api.logout(),
          throwsA(isA<AppFailure>().having((e) => e.status, 'status', 403)),
        );
      } finally {
        api.close();
      }
    },
  );

  test(
    'logout issues an authenticated server revocation without leaking the response',
    () async {
      final requests = <http.Request>[];
      final api = JellyfinLibrary(
        const ServerSession('https://example.com', 'u', 'fixture', 'u'),
        client: MockClient((r) async {
          requests.add(r);
          return http.Response('', 204);
        }),
      );
      try {
        await api.logout();
        expect(requests.single.method, 'POST');
        expect(requests.single.url.path, '/Sessions/Logout');
        expect(requests.single.headers['Authorization'], contains('Token='));
      } finally {
        api.close();
      }
    },
  );
}
