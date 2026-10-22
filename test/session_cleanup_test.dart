import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:just_audio/just_audio.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:simplefy/application/app_controller.dart';
import 'package:simplefy/domain/queue_engine.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/infrastructure/download_manager.dart';
import 'package:simplefy/infrastructure/jellyfin_library.dart';
import 'package:simplefy/infrastructure/local_store.dart';
import 'package:simplefy/infrastructure/music_audio_handler.dart';
import 'download_activity_test.dart' show MemoryDownloadBackend;

class SessionStore extends LocalStore {
  SessionStore(super.directory);
  bool sessionDeleted = false;
  bool sessionSaved = false;
  @override
  Future<void> saveSession(String value) async {
    sessionSaved = true;
  }

  final writtenKeys = <String>[];
  @override
  Future<void> write(String key, Map<String, dynamic> value) {
    writtenKeys.add(key);
    return super.write(key, value);
  }

  @override
  Future<void> deleteSession() async {
    sessionDeleted = true;
  }
}

class IdlePlayer implements AudioPlayer {
  @override
  Duration get position => Duration.zero;
  @override
  bool get playing => false;
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class SilentHandler implements MusicAudioHandler {
  @override
  final player = IdlePlayer();
  @override
  void publishQueue(QueueEngine engine, {Duration? position}) {}
  @override
  void cancelGainAdjustment() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'failed account attachment rolls back partial services without erasing the valid login',
    () async {
      final dir = await Directory.systemTemp.createTemp('simplefy-attach-');
      final store = SessionStore(dir);
      final backend = MemoryDownloadBackend();
      final app = AppController(
        store,
        SilentHandler(),
        authenticate: (_, username, _, _) async =>
            ServerSession('https://example.com', 'u', 'fixture', username),
        libraryFactory: (session, _) => JellyfinLibrary(session),
        downloadFactory: (store, api) =>
            DownloadManager(store, api, backend: backend),
        cacheDirectory: () async =>
            throw const FileSystemException('fixture cache unavailable'),
      );
      try {
        await expectLater(
          app.login('https://example.com', 'fixture', 'fixture'),
          throwsA(isA<FileSystemException>()),
        );
        expect(app.library, isNull);
        expect(app.downloads, isNull);
        expect(app.loggedIn, false);
        expect(app.localPlaylists.items, isEmpty);
        expect(app.queue.entries, isEmpty);
        expect(store.sessionSaved, true);
        expect(store.sessionDeleted, false);
      } finally {
        app.dispose();
        await backend.events.close();
        await store.write('flush', {});
        await dir.delete(recursive: true);
      }
    },
  );

  test('periodic position persistence never rewrites a large queue', () async {
    final dir = await Directory.systemTemp.createTemp('simplefy-playhead-');
    final store = SessionStore(dir);
    final app = AppController(store, SilentHandler())..initialized = true;
    try {
      app.queue.replace(
        List.generate(
          10000,
          (i) => LibraryItem(
            id: 'track-$i',
            name: 'Track $i',
            kind: ItemKind.track,
          ),
        ),
      );
      await app.save();
      final state = await store.read('state_local');
      expect(((state['queue'] as Map)['entries'] as List).length, 10000);
      store.writtenKeys.clear();
      await app.savePosition();
      expect(store.writtenKeys, ['playhead_state_local']);
      expect(
        (await store.read('playhead_state_local'))['entryId'],
        app.queue.current!.id,
      );
    } finally {
      app.dispose();
      await store.write('flush', {});
      await dir.delete(recursive: true);
    }
  });

  test(
    'logout clears saved session and task headers even if server revocation fails',
    () async {
      final dir = await Directory.systemTemp.createTemp('simplefy-logout-');
      final store = SessionStore(dir);
      final backend = MemoryDownloadBackend();
      var revokeCalls = 0;
      final api = JellyfinLibrary(
        const ServerSession('https://example.com', 'u', 'fixture', 'u'),
        client: MockClient((request) async {
          expect(request.url.path, '/Sessions/Logout');
          revokeCalls++;
          return http.Response('', 503);
        }),
      );
      final manager = DownloadManager(store, api, backend: backend);
      final app = AppController(store, SilentHandler())
        ..library = api
        ..downloads = manager;
      try {
        final file = File('${dir.path}/music/${manager.namespace}/song.flac');
        await file.parent.create(recursive: true);
        await file.writeAsBytes([1, 2, 3, 4]);
        await store.write('downloads_${manager.namespace}', {
          'files': {'song': 'song.flac'},
          'fileSizes': {'song': 4},
        });
        await manager.initialize();
        final task = DownloadTask(
          url: 'https://example.com/file',
          group: manager.namespace,
          headers: {'Authorization': 'fixture'},
          metaData: 'pending',
        );
        await backend.enqueue(task);
        await app.logout();
        expect(revokeCalls, 1);
        expect(store.sessionDeleted, true);
        expect(backend.active, isEmpty);
        expect(backend.history, isEmpty);
        expect(app.library, isNull);
        expect(app.downloads, isNull);
        expect(await file.readAsBytes(), [1, 2, 3, 4]);
        final saved = await store.read('downloads_${manager.namespace}');
        expect(saved['taskIds'], isEmpty);
        expect(saved['files'], {'song': 'song.flac'});
      } finally {
        app.dispose();
        await backend.events.close();
        await store.write('flush', {});
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'download invalidation independently refuses to destroy healthy bytes',
    () async {
      final dir = await Directory.systemTemp.createTemp('simplefy-file-check-');
      final store = LocalStore(dir);
      final backend = MemoryDownloadBackend();
      final api = JellyfinLibrary(
        const ServerSession('https://example.com', 'u', 'fixture', 'u'),
      );
      final manager = DownloadManager(store, api, backend: backend);
      try {
        final file = File('${dir.path}/music/${manager.namespace}/song.flac');
        await file.parent.create(recursive: true);
        await file.writeAsBytes([1, 2, 3, 4]);
        await store.write('downloads_${manager.namespace}', {
          'files': {'song': 'song.flac'},
          'fileSizes': {'song': 4},
        });
        await manager.initialize();
        await manager.invalidate('song');
        expect(manager.contains('song'), true);
        expect(await file.readAsBytes(), [1, 2, 3, 4]);
        await file.writeAsBytes([1, 2]);
        await manager.invalidate('song');
        expect(manager.contains('song'), false);
        expect(await file.exists(), false);
      } finally {
        manager.dispose();
        api.close();
        await backend.events.close();
        await store.write('flush', {});
        await dir.delete(recursive: true);
      }
    },
  );
}
