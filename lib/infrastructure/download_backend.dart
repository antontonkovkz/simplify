import 'dart:async';
import 'package:background_downloader/background_downloader.dart';

/// Native task transport; download policy stays in DownloadManager.
abstract interface class DownloadBackend {
  Stream<TaskUpdate> get updates;
  Future<void> start();
  Future<void> reconcile();
  Future<List<TaskRecord>> records(String group);
  Future<Task?> task(String id);
  Future<bool> enqueue(DownloadTask task);
  Future<bool> resume(DownloadTask task);
  Future<void> cancel(String id);
  Future<void> forgetGroup(String group);
}

class NativeDownloadBackend implements DownloadBackend {
  // The plugin's single-subscription stream is shared across account changes.
  static final _events = FileDownloader().updates.asBroadcastStream();
  static Future<void>? _started;
  @override
  Stream<TaskUpdate> get updates => _events;
  @override
  Future<void> start() async => await (_started ??= FileDownloader().start());
  @override
  Future<void> reconcile() => FileDownloader().resumeFromBackground();
  @override
  Future<List<TaskRecord>> records(String group) =>
      FileDownloader().database.allRecords(group: group);
  @override
  Future<Task?> task(String id) => FileDownloader().taskForId(id);
  @override
  Future<bool> enqueue(DownloadTask task) => FileDownloader().enqueue(task);
  @override
  Future<bool> resume(DownloadTask task) => FileDownloader().resume(task);
  @override
  Future<void> forgetGroup(String group) async {
    await FileDownloader().reset(group: group);
    await FileDownloader().database.deleteAllRecords(group: group);
  }

  @override
  Future<void> cancel(String id) async {
    await FileDownloader().cancelTaskWithId(id);
  }
}
