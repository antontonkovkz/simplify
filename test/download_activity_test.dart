import 'package:http/http.dart' as http;
import 'dart:async';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simplefy/application/ports.dart';
import 'package:simplefy/domain/download_group.dart';
import 'package:simplefy/domain/library_item.dart';
import 'package:simplefy/infrastructure/download_backend.dart';
import 'package:simplefy/infrastructure/download_manager.dart';
import 'package:simplefy/infrastructure/jellyfin_library.dart';
import 'package:simplefy/infrastructure/local_store.dart';
import 'compact_ui_test.dart' show songs, folder;

class MemoryDownloadBackend implements DownloadBackend {
  final events = StreamController<TaskUpdate>.broadcast(sync: true);
  final active = <String, DownloadTask>{};
  final history = <String, TaskRecord>{};
  final enqueued = <DownloadTask>[];
  final resumed = <String>[];
  Completer<void>? lookupGate;
  bool accepts = true;
  void Function()? onEnqueue;
  @override
  Stream<TaskUpdate> get updates => events.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> reconcile() async {}
  @override
  Future<List<TaskRecord>> records(String group) async =>
      history.values.where((r) => r.group == group).toList();
  @override
  Future<Task?> task(String id) async {
    await lookupGate?.future;
    return active[id];
  }

  @override
  Future<bool> enqueue(DownloadTask task) async {
    enqueued.add(task);
    onEnqueue?.call();
    if (accepts) {
      active[task.taskId] = task;
      emit(task, TaskStatus.enqueued);
    }
    return accepts;
  }

  @override
  Future<bool> resume(DownloadTask task) async {
    resumed.add(task.taskId);
    emit(task, TaskStatus.running);
    return true;
  }

  @override
  Future<void> forgetGroup(String group) async {
    active.removeWhere((_, task) => task.group == group);
    history.removeWhere((_, record) => record.group == group);
  }

  @override
  Future<void> cancel(String id) async {
    final task = active.remove(id);
    if (task != null) emit(task, TaskStatus.canceled);
  }

  void emit(DownloadTask task, TaskStatus status, [TaskException? exception]) {
    history[task.taskId] = TaskRecord(task, status, 0, -1, exception);
    if (status.isFinalState) active.remove(task.taskId);
    events.add(TaskStatusUpdate(task, status, exception));
  }

  void fraction(DownloadTask task, double value) =>
      events.add(TaskProgressUpdate(task, value));
}

class DownloadFixtureLibrary extends JellyfinLibrary {
  DownloadFixtureLibrary()
    : super(
        const ServerSession(
          'https://example.com',
          'fixture',
          'fixture',
          'fixture',
        ),
      );
  @override
  Map<String, String> get headers => {};
  @override
  Future<void> prepareDownload(
    LibraryItem track, {
    http.Client? transport,
  }) async {}
  @override
  bool requiresConversion(LibraryItem track) => false;
  @override
  Uri downloadUri(LibraryItem track) =>
      Uri.parse('https://example.com/${track.id}');
}

class SnapshotDownloads extends DownloadManager {
  SnapshotDownloads(
    super.store,
    super.library, {
    required super.backend,
    super.retryDelay,
    super.stallTimeout,
  });
  Completer<DownloadGroup>? gate;
  Object? failure;
  int snapshots = 0;
  @override
  Future<DownloadGroup> snapshot(LibraryItem source) async {
    snapshots++;
    if (failure case final error?) throw error;
    return gate?.future ?? DownloadGroup(source: source, tracks: songs);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late LocalStore store;
  late MemoryDownloadBackend backend;
  late SnapshotDownloads manager;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('simplefy-transfers-');
    store = LocalStore(directory);
    backend = MemoryDownloadBackend();
    manager = SnapshotDownloads(
      store,
      DownloadFixtureLibrary(),
      backend: backend,
    );
    await manager.initialize();
  });
  tearDown(() async {
    manager.dispose();
    await store.write('flush', {});
    await backend.events.close();
    await directory.delete(recursive: true);
  });

  test(
    'batch deduplicates shared songs, includes partial progress and hides on completion',
    () async {
      await manager.apply(
        DownloadGroup(source: folder, tracks: songs.take(2).toList()),
      );
      const playlist = LibraryItem(id: 'p', name: 'P', kind: ItemKind.playlist);
      await manager.apply(DownloadGroup(source: playlist, tracks: songs));
      expect(backend.enqueued, hasLength(3));
      final tasks = backend.enqueued;
      backend.emit(tasks[0], TaskStatus.complete);
      backend.emit(tasks[1], TaskStatus.running);
      backend.emit(tasks[2], TaskStatus.running);
      backend.fraction(tasks[1], .5);
      final status = manager.activity!;
      expect(status.total, 3);
      expect(status.completed, 1);
      expect(status.remaining, 2);
      expect(status.fraction, .5);
      expect(status.currentTrack, songs[1].title);
      expect(status.activeCount, 2);
      expect(manager.activity, same(status));
      backend.emit(tasks[1], TaskStatus.complete);
      backend.emit(tasks[2], TaskStatus.complete);
      expect(manager.activity, null);
    },
  );

  test(
    'connection failure is visible and recovery automatically retries without duplicates',
    () async {
      await manager.apply(DownloadGroup(source: folder, tracks: [songs.first]));
      final old = backend.enqueued.single;
      backend.emit(
        old,
        TaskStatus.failed,
        TaskConnectionException('private URL must not be displayed'),
      );
      expect(manager.activity!.failedCount, 1);
      expect(manager.activity!.detail, contains('соединения'));
      expect(manager.activity!.detail, isNot(contains('private URL')));
      manager.setNetwork(NetworkKind.offline);
      expect(manager.activity!.detail, contains('Соединение потеряно'));
      await manager.retryPending(manual: true);
      expect(backend.enqueued, hasLength(1));
      manager.setNetwork(NetworkKind.unmetered);
      await manager.retryPending();
      expect(backend.enqueued, hasLength(2));
      await Future.wait([
        manager.retryPending(manual: true),
        manager.retryPending(manual: true),
      ]);
      expect(backend.enqueued, hasLength(2));
      backend.emit(
        old,
        TaskStatus.failed,
        TaskConnectionException('late failure'),
      );
      expect(manager.errors, isEmpty);
    },
  );

  test(
    'failed connection retries automatically even when the network type stays unchanged',
    () async {
      manager.dispose();
      manager = SnapshotDownloads(
        store,
        DownloadFixtureLibrary(),
        backend: backend,
        retryDelay: const Duration(milliseconds: 30),
      );
      await manager.initialize();
      await manager.apply(DownloadGroup(source: folder, tracks: [songs.first]));
      final retried = Completer<void>();
      backend.onEnqueue = () {
        if (backend.enqueued.length == 2) retried.complete();
      };
      backend.emit(
        backend.enqueued.single,
        TaskStatus.failed,
        TaskConnectionException('network'),
      );
      await retried.future.timeout(const Duration(seconds: 2));
      expect(backend.enqueued, hasLength(2));
    },
  );

  test(
    'silent native reconnect exposes a stalled status and manual continuation',
    () async {
      manager.dispose();
      manager = SnapshotDownloads(
        store,
        DownloadFixtureLibrary(),
        backend: backend,
        stallTimeout: const Duration(milliseconds: 30),
      );
      await manager.initialize();
      await manager.apply(DownloadGroup(source: folder, tracks: [songs.first]));
      backend.emit(backend.enqueued.single, TaskStatus.running);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(manager.activity!.detail, contains('не передаёт данные'));
      expect(manager.activity!.canContinue, true);
      await manager.retryPending(manual: true);
      expect(backend.enqueued, hasLength(2));
    },
  );

  test(
    'automatic retry preserves native backoff and manual retry advances it',
    () async {
      await manager.apply(DownloadGroup(source: folder, tracks: [songs.first]));
      backend.emit(backend.enqueued.single, TaskStatus.waitingToRetry);
      expect(manager.activity!.canContinue, true);
      expect(manager.activity!.detail, contains('прервано'));
      await manager.retryPending();
      expect(backend.enqueued, hasLength(1));
      await manager.retryPending(manual: true);
      expect(backend.enqueued, hasLength(2));
    },
  );

  test('paused task resumes instead of downloading a duplicate', () async {
    await manager.apply(DownloadGroup(source: folder, tracks: [songs.first]));
    final task = backend.enqueued.single;
    backend.emit(task, TaskStatus.paused);
    await manager.retryPending(manual: true);
    expect(backend.resumed, [task.taskId]);
    expect(backend.enqueued, hasLength(1));
  });

  test('missing or unauthorized tracks require manual retry', () async {
    await manager.apply(DownloadGroup(source: folder, tracks: [songs.first]));
    backend.emit(backend.enqueued.last, TaskStatus.notFound);
    expect(manager.activity!.detail, contains('отсутствует'));
    await manager.retryPending();
    expect(backend.enqueued, hasLength(1));
    await manager.retryPending(manual: true);
    expect(backend.enqueued, hasLength(2));
    backend.emit(
      backend.enqueued.last,
      TaskStatus.failed,
      TaskHttpException('private response', 403),
    );
    await manager.retryPending();
    expect(backend.enqueued, hasLength(2));
    expect(manager.activity!.detail, contains('доступ'));
  });

  test('a lingering final native record cannot block recovery', () async {
    await manager.apply(DownloadGroup(source: folder, tracks: [songs.first]));
    final old = backend.enqueued.single;
    backend.emit(old, TaskStatus.failed, TaskConnectionException('network'));
    backend.active[old.taskId] = old;
    await manager.retryPending(manual: true);
    expect(backend.enqueued, hasLength(2));
  });

  test('Wi-Fi preference is respected even by manual continuation', () async {
    manager.allowCellular = false;
    manager.setNetwork(NetworkKind.cellular);
    await manager.apply(DownloadGroup(source: folder, tracks: [songs.first]));
    expect(backend.enqueued.single.requiresWiFi, true);
    backend.emit(
      backend.enqueued.single,
      TaskStatus.failed,
      TaskConnectionException('network'),
    );
    await manager.retryPending(manual: true);
    expect(backend.enqueued, hasLength(1));
    expect(manager.activity!.detail, contains('Wi-Fi'));
    manager.setNetwork(NetworkKind.unmetered);
    await manager.retryPending();
    expect(backend.enqueued, hasLength(2));
  });

  test(
    'preparation is visible before metadata arrives and can recover after failure',
    () async {
      manager.gate = Completer<DownloadGroup>();
      final add = manager.add(folder);
      expect(manager.activity!.preparing, true);
      expect(manager.activity!.currentTrack, folder.name);
      manager.gate!.completeError(const AppFailure('network'));
      await expectLater(add, throwsA(isA<AppFailure>()));
      expect(manager.activity!.canContinue, true);
      manager.gate = null;
      await manager.retryPending(manual: true);
      expect(manager.snapshots, 2);
      expect(backend.enqueued, hasLength(3));
      expect(manager.activity!.total, 3);
    },
  );

  test(
    'removing downloads during retry never resurrects their tasks',
    () async {
      await manager.apply(DownloadGroup(source: folder, tracks: [songs.first]));
      backend.emit(
        backend.enqueued.single,
        TaskStatus.failed,
        TaskConnectionException('network'),
      );
      backend.lookupGate = Completer<void>();
      final retry = manager.retryPending();
      await Future<void>.delayed(Duration.zero);
      final clear = manager.clear();
      backend.lookupGate!.complete();
      await retry;
      await clear;
      expect(backend.enqueued, hasLength(1));
      expect(manager.activity, null);
    },
  );

  test(
    'restart adopts a newer native attempt before the saved task ID catches up',
    () async {
      await manager.apply(DownloadGroup(source: folder, tracks: [songs.first]));
      final old = backend.enqueued.single;
      await manager.reconcile();
      manager.dispose();
      final latest = old.copyWith(
        taskId: 'newer-attempt',
        creationTime: old.creationTime.add(const Duration(seconds: 1)),
      );
      backend.active.remove(old.taskId);
      backend.active[latest.taskId] = latest;
      backend.history[latest.taskId] = TaskRecord(
        latest,
        TaskStatus.running,
        .5,
        100,
      );
      manager = SnapshotDownloads(
        store,
        DownloadFixtureLibrary(),
        backend: backend,
      );
      await manager.initialize();
      await manager.retryPending(manual: true);
      expect(backend.enqueued, hasLength(1));
      backend.emit(
        old,
        TaskStatus.failed,
        TaskConnectionException('old failure'),
      );
      expect(manager.errors, isEmpty);
      expect(manager.activity!.fraction, .5);
    },
  );

  test(
    'restart restores failed tasks and the batch progress, then retries safely',
    () async {
      await manager.apply(
        DownloadGroup(source: folder, tracks: songs.take(2).toList()),
      );
      final task = backend.enqueued.first;
      final file = File('${directory.path}/${task.directory}/${task.filename}');
      await file.parent.create(recursive: true);
      await file.writeAsBytes([1, 2, 3]);
      backend.emit(task, TaskStatus.complete);
      backend.emit(
        backend.enqueued.last,
        TaskStatus.failed,
        TaskConnectionException('network'),
      );
      await manager.reconcile();
      manager.dispose();
      manager = SnapshotDownloads(
        store,
        DownloadFixtureLibrary(),
        backend: backend,
      );
      await manager.initialize();
      expect(manager.activity!.total, 2);
      expect(manager.activity!.completed, 1);
      expect(manager.activity!.failedCount, 1);
      await manager.retryPending();
      expect(backend.enqueued, hasLength(3));
    },
  );
}
