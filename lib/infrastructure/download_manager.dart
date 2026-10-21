import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../domain/download_group.dart';
import '../domain/download_activity.dart';
import 'download_backend.dart';
import '../domain/library_item.dart';
import '../application/ports.dart';
import '../application/serial_executor.dart';
import 'jellyfin_library.dart';
import 'local_store.dart';

class DownloadManager extends ChangeNotifier {
  DownloadManager(
    this.store,
    this.library, {
    DownloadBackend? backend,
    this.retryDelay = const Duration(seconds: 20),
    this.stallTimeout = const Duration(seconds: 20),
  }) : backend = backend ?? NativeDownloadBackend();
  final DownloadBackend backend;
  final LocalStore store;
  final JellyfinLibrary library;
  final Map<String, DownloadGroup> groups = {};
  final Map<String, String> _files = {};
  List<LibraryItem>? _completedTracks;
  final Map<String, double> progress = {};
  final Map<String, String> errors = {};
  final Map<String, String> _taskIds = {};
  StreamSubscription<TaskUpdate>? _subscription;
  Timer? _notificationTimer;
  Timer? _saveTimer;
  bool _disposed = false;
  final _mutations = SerialExecutor();
  final Map<String, int> _sourceVersions = {};
  int _generation = 0;
  bool allowCellular = true;
  NetworkKind _network = NetworkKind.other;
  final Map<String, LibraryItem> _batch = {};
  final Map<String, LibraryItem> _pendingSources = {};
  final Map<String, String> _preparationErrors = {};
  final Set<String> _preparing = {};
  final Set<String> _retryableSources = {};
  final Map<String, TaskStatus> _statuses = {};
  final Set<String> _retryable = {};
  Timer? _retryTimer;
  Future<void>? _retrying;
  DownloadActivity? _activity;
  bool _activityDirty = true;
  final Duration retryDelay;
  final Duration stallTimeout;
  final Map<String, DateTime> _lastActivity = {};
  final Set<String> _stalled = {};
  Timer? _stallTimer;

  void _scheduleStallCheck() {
    _stallTimer?.cancel();
    if (_disposed || !_networkAllowed) return;
    final now = DateTime.now();
    Duration? earliest;
    for (final entry in _lastActivity.entries) {
      if (_statuses[entry.key] != TaskStatus.running ||
          _stalled.contains(entry.key)) {
        continue;
      }
      final delay = stallTimeout - now.difference(entry.value);
      if (earliest == null || delay < earliest) earliest = delay;
    }
    if (earliest == null) return;
    _stallTimer = Timer(earliest.isNegative ? Duration.zero : earliest, () {
      final now = DateTime.now();
      for (final entry in _lastActivity.entries) {
        if (_statuses[entry.key] == TaskStatus.running &&
            now.difference(entry.value) >= stallTimeout) {
          _stalled.add(entry.key);
        }
      }
      _changed();
    });
  }

  bool get _networkAllowed =>
      _network != NetworkKind.offline &&
      (allowCellular || _network != NetworkKind.cellular);

  void setNetwork(NetworkKind value) {
    final wasAllowed = _networkAllowed;
    _network = value;
    _changed(immediate: true);
    if (_networkAllowed && !wasAllowed) unawaited(retryPending());
    _scheduleRetry();
  }

  DownloadActivity? get activity {
    if (!_activityDirty) return _activity;
    _activityDirty = false;
    final remaining = _batch.values
        .where((track) => !contains(track.id))
        .toList();
    if (remaining.isEmpty &&
        _pendingSources.isEmpty &&
        !errors.containsKey('_storage')) {
      return _activity = null;
    }
    final active = remaining
        .where((track) => _statuses[track.id] == TaskStatus.running)
        .toList();
    final failed =
        remaining.where((track) => errors.containsKey(track.id)).length +
        _preparationErrors.length +
        (errors.containsKey('_transport') ? 1 : 0) +
        (errors.containsKey('_storage') ? 1 : 0);
    final retrying = remaining.any(
      (track) => _statuses[track.id] == TaskStatus.waitingToRetry,
    );
    final paused = remaining.any(
      (track) =>
          _statuses[track.id] == TaskStatus.paused ||
          _statuses[track.id] == TaskStatus.canceled,
    );
    final preparing = _preparing.isNotEmpty;
    final total = _batch.length;
    final completed = total - remaining.length;
    final partial = remaining.fold<double>(
      0,
      (sum, track) => sum + (progress[track.id] ?? 0).clamp(0, 1),
    );
    String? detail;
    if (_network == NetworkKind.offline) {
      detail =
          'Соединение потеряно. Продолжим автоматически, когда появится сеть.';
    } else if (!_networkAllowed) {
      detail = 'Ожидаем Wi-Fi. Загрузка через мобильную сеть выключена.';
    } else if (_stalled.isNotEmpty) {
      detail = 'Сервер не передаёт данные. Ожидаем восстановления соединения.';
    } else if (_preparationErrors.isNotEmpty) {
      detail = _preparationErrors.values.first;
    } else if (errors.isNotEmpty) {
      detail = errors.values.first;
    } else if (retrying) {
      detail = 'Соединение прервано. Выполняется автоматический повтор.';
    } else if (paused) {
      detail = 'Загрузка приостановлена. Можно продолжить.';
    }
    return _activity = DownloadActivity(
      total: total,
      completed: completed,
      fraction: total == 0 ? 0 : ((completed + partial) / total).clamp(0, 1),
      title: !_networkAllowed
          ? 'Загрузка ожидает сеть'
          : failed > 0
          ? 'Ошибка загрузки'
          : preparing
          ? 'Подготовка загрузки'
          : 'Загрузка музыки',
      detail: detail,
      currentTrack: active.isNotEmpty
          ? active.first.title
          : remaining.isNotEmpty
          ? remaining.first.title
          : _pendingSources.values.firstOrNull?.name,
      activeCount: active.length,
      failedCount: failed,
      canContinue:
          !_networkAllowed ||
          failed > 0 ||
          retrying ||
          paused ||
          _stalled.isNotEmpty,
      continuing: _retrying != null,
      preparing: preparing && total == 0,
    );
  }

  void _includeBatch(Iterable<LibraryItem> tracks) {
    if (_batch.values.every((track) => contains(track.id))) _batch.clear();
    for (final track in tracks) {
      if (!contains(track.id)) _batch[track.id] = track;
    }
    _activityDirty = true;
  }

  void _scheduleRetry() {
    if (_disposed ||
        !_networkAllowed ||
        (_retryable.isEmpty && _retryableSources.isEmpty)) {
      _retryTimer?.cancel();
      _retryTimer = null;
      return;
    }
    if (_retrying != null) return;
    _retryTimer ??= Timer(retryDelay, () {
      _retryTimer = null;
      unawaited(retryPending());
    });
  }

  Future<void> retryPending({bool manual = false}) {
    if (_disposed) return Future.value();
    if (_retrying case final running?) return running;
    late final Future<void> operation;
    operation =
        Future<void>(() async {
              final generation = _generation;
              if (!_networkAllowed || _disposed) return;
              errors.remove('_transport');
              for (final source in List.of(_pendingSources.values)) {
                if (_disposed ||
                    !_networkAllowed ||
                    generation != _generation) {
                  return;
                }
                if (_preparing.contains(source.id) ||
                    (!manual && !_retryableSources.contains(source.id))) {
                  continue;
                }
                try {
                  await add(source);
                } catch (_) {
                  /* The banner retains the error. */
                }
              }
              await _mutations.run(() async {
                final tracks = {
                  for (final group in groups.values)
                    for (final track in group.tracks) track.id: track,
                };
                for (final track in tracks.values) {
                  if (_disposed ||
                      generation != _generation ||
                      !_networkAllowed) {
                    return;
                  }
                  if (contains(track.id)) continue;
                  final status = _statuses[track.id];
                  if (!manual &&
                      errors.containsKey(track.id) &&
                      !_retryable.contains(track.id)) {
                    continue;
                  }
                  final id = _taskIds[track.id];
                  final task = id == null ? null : await backend.task(id);
                  if (_disposed ||
                      generation != _generation ||
                      !groups.values.any(
                        (group) =>
                            group.tracks.any((item) => item.id == track.id),
                      )) {
                    return;
                  }
                  if (task != null &&
                      status == TaskStatus.paused &&
                      task is DownloadTask) {
                    if (await backend.resume(task)) {
                      _statuses[track.id] = TaskStatus.enqueued;
                      _lastActivity.remove(track.id);
                      _stalled.remove(track.id);
                      continue;
                    }
                    await backend.cancel(task.taskId);
                    _taskIds.remove(track.id);
                  } else if (task != null &&
                      ((status?.isFinalState ?? false) ||
                          (manual &&
                              (status == TaskStatus.waitingToRetry ||
                                  _stalled.contains(track.id))))) {
                    // A manual retry advances the backoff without duplicating it.
                    await backend.cancel(task.taskId);
                    _taskIds.remove(track.id);
                  } else if (task != null) {
                    continue;
                  }
                  if (_disposed || generation != _generation) return;
                  await _enqueue(track);
                }
                await _save();
              });
            })
            .catchError((Object error) {
              if (_disposed) return;
              errors['_transport'] =
                  'Не удалось восстановить загрузки. Повторим автоматически.';
              _retryable.addAll(_batch.keys.where((id) => !contains(id)));
            })
            .whenComplete(() {
              if (identical(_retrying, operation)) _retrying = null;
              _changed();
              _scheduleRetry();
            });
    _retrying = operation;
    _changed(immediate: true);
    return operation;
  }

  String get namespace => base64Url
      .encode(
        utf8.encode('${library.session.server}|${library.session.userId}'),
      )
      .replaceAll('=', '');
  String get _key => 'downloads_$namespace';
  String get _directory => 'music/$namespace';

  Future<void> initialize() async {
    final saved = await store.read(_key);
    for (final raw in saved['groups'] as List? ?? []) {
      final group = DownloadGroup.fromJson(
        Map<String, dynamic>.from(raw as Map),
      );
      groups[group.source.id] = group;
    }
    _files.addAll((saved['files'] as Map? ?? {}).cast<String, String>());
    _taskIds.addAll((saved['taskIds'] as Map? ?? {}).cast<String, String>());
    final metadata = {
      for (final group in groups.values)
        for (final track in group.tracks) track.id: track,
    };
    for (final id in saved['batchIds'] as List? ?? []) {
      if (metadata[id] case final track?) _batch[track.id] = track;
    }
    for (final raw in saved['pendingSources'] as List? ?? []) {
      final source = LibraryItem.fromJson(
        Map<String, dynamic>.from(raw as Map),
      );
      _pendingSources[source.id] = source;
      _preparationErrors[source.id] =
          'Подготовка загрузки не завершена. Можно продолжить.';
      if ((saved['retrySources'] as List? ?? []).contains(source.id)) {
        _retryableSources.add(source.id);
      }
    }
    _subscription = backend.updates.listen(_update);
    await backend.start();
    await _restoreRecords();
    final missing = <String>[];
    for (final id in List.of(_files.keys)) {
      if (!await File(_path(_files[id]!)).exists()) missing.add(id);
    }
    for (final id in missing) {
      _files.remove(id);
    }
    _includeBatch(metadata.values);
    await _save();
    _changed();
    _scheduleRetry();
  }

  Future<void> reconcile() => _mutations.run(() async {
    await backend.reconcile();
    await _restoreRecords();
    await _save();
    _changed();
  });

  Future<void> _restoreRecords() async {
    final referenced = groups.values
        .expand((g) => g.tracks)
        .map((t) => t.id)
        .toSet();
    final records = List.of(await backend.records(namespace))
      ..sort((a, b) => b.task.creationTime.compareTo(a.task.creationTime));
    final seen = <String>{};
    for (final record in records) {
      final id = record.task.metaData;
      if (!referenced.contains(id) || !seen.add(id)) continue;
      // The database may contain a newer attempt than the last saved task ID.
      // A newly enqueued live task may, in turn, not be in the database yet.
      if (_taskIds[id] case final current?) {
        if (current != record.task.taskId) {
          final live = await backend.task(current);
          if (live != null &&
              live.creationTime.isAfter(record.task.creationTime)) {
            continue;
          }
        }
      }
      _taskIds[id] = record.task.taskId;
      _statuses[id] = record.status;
      if (record.status == TaskStatus.running) {
        _lastActivity[id] = DateTime.now();
      }
      if (record.status == TaskStatus.complete &&
          await File(_path(record.task.filename)).exists()) {
        _files[id] = record.task.filename;
        progress.remove(id);
        errors.remove(id);
      } else if (record.status == TaskStatus.failed ||
          record.status == TaskStatus.notFound) {
        _recordFailure(id, record.status, record.exception);
      } else if (!record.status.isFinalState && !_files.containsKey(id)) {
        progress[id] = record.progress.clamp(0, 1);
      }
    }
  }

  void _scheduleSave() {
    if (_disposed) return;
    _saveTimer ??= Timer(const Duration(milliseconds: 500), () {
      _saveTimer = null;
      unawaited(
        _save().catchError((Object error) {
          errors['_storage'] = 'Не удалось сохранить состояние загрузок';
          _changed();
        }),
      );
    });
  }

  String _path(String name) => p.join(store.directory.path, _directory, name);
  bool contains(String id) => _files.containsKey(id);
  String? localPath(String id) =>
      _files[id] == null ? null : _path(_files[id]!);
  int get completedCount => _files.length;

  /// Completed files appear once even when referenced by several downloads.
  List<LibraryItem> get completedTracks => _completedTracks ??= () {
    final metadata = {
      for (final group in groups.values)
        for (final track in group.tracks) track.id: track,
    };
    final tracks = [
      for (final entry in _files.entries)
        metadata[entry.key] ??
            LibraryItem(
              id: entry.key,
              name: entry.value,
              fileName: entry.value,
              kind: ItemKind.track,
            ),
    ]..sort(compareItems);
    return List<LibraryItem>.unmodifiable(tracks);
  }();

  Future<void> invalidate(String id) async {
    final filename = _files.remove(id);
    if (filename != null) {
      final file = File(_path(filename));
      if (await file.exists()) await file.delete();
    }
    errors[id] = 'Локальный файл недоступен. Повторите загрузку.';
    await _save();
    _changed();
  }

  Future<void> _save() async {
    _completedTracks = null;
    await store.write(_key, {
      'groups': groups.values.map((e) => e.toJson()).toList(),
      'files': Map.of(_files),
      'taskIds': Map.of(_taskIds),
      'batchIds': _batch.keys.toList(),
      'retrySources': _retryableSources.toList(),
      'pendingSources': _pendingSources.values
          .map((source) => source.toJson())
          .toList(),
    });
    if (errors.remove('_storage') != null) _changed();
  }

  void _changed({bool immediate = false}) {
    _activityDirty = true;
    if (_disposed) return;
    _scheduleStallCheck();
    if (immediate) {
      _notificationTimer?.cancel();
      _notificationTimer = null;
      notifyListeners();
      return;
    }
    _notificationTimer ??= Timer(const Duration(milliseconds: 150), () {
      _notificationTimer = null;
      notifyListeners();
    });
  }

  void _update(TaskUpdate update) {
    if (update.task.group != namespace) return;
    final id = update.task.metaData;
    if (!groups.values.any(
      (group) => group.tracks.any((track) => track.id == id),
    )) {
      return;
    }
    if (_taskIds[id] != null && _taskIds[id] != update.task.taskId) return;
    _taskIds[id] = update.task.taskId;
    if (update is TaskProgressUpdate) {
      if (update.progress >= 0) {
        progress[id] = update.progress.clamp(0, 1);
        _lastActivity[id] = DateTime.now();
        _stalled.remove(id);
      }
    } else if (update is TaskStatusUpdate) {
      _statuses[id] = update.status;
      _stalled.remove(id);
      if (update.status == TaskStatus.running) {
        _lastActivity[id] = DateTime.now();
      } else {
        _lastActivity.remove(id);
      }
      if (update.status == TaskStatus.complete) {
        // A cancelled/removed group must not resurrect a completed file.
        if (groups.values.any((g) => g.tracks.any((t) => t.id == id))) {
          _files[id] = update.task.filename;
          _completedTracks = null;
          errors.remove(id);
          _retryable.remove(id);
          _scheduleSave();
        }
        progress.remove(id);
      } else if (update.status == TaskStatus.failed ||
          update.status == TaskStatus.notFound) {
        _recordFailure(id, update.status, update.exception);
        _scheduleSave();
      } else if (update.status == TaskStatus.canceled) {
        progress.remove(id);
      } else {
        if (update.status == TaskStatus.running ||
            update.status == TaskStatus.enqueued) {
          errors.remove(id);
          _retryable.remove(id);
        }
        progress.putIfAbsent(id, () => 0);
      }
    }
    _changed();
    _scheduleRetry();
  }

  void _recordFailure(String id, TaskStatus status, TaskException? exception) {
    final code = exception is TaskHttpException
        ? exception.httpResponseCode
        : null;
    final missing = status == TaskStatus.notFound || code == 404;
    final access = code == 401 || code == 403;
    final storage = exception is TaskFileSystemException;
    errors[id] = missing
        ? 'Композиция отсутствует на сервере.'
        : access
        ? 'Сервер отклонил доступ. Проверьте учётную запись.'
        : storage
        ? 'Не удалось записать файл. Проверьте свободное место.'
        : exception is TaskUrlException
        ? 'Некорректный адрес загрузки. Проверьте сервер.'
        : code != null &&
              code >= 400 &&
              code < 500 &&
              code != 408 &&
              code != 429
        ? 'Сервер отклонил загрузку (HTTP $code).'
        : 'Ошибка соединения. Продолжим автоматически; можно повторить вручную.';
    progress.remove(id);
    if (!missing &&
        !access &&
        !storage &&
        exception is! TaskUrlException &&
        (code == null || code >= 500 || code == 408 || code == 429)) {
      _retryable.add(id);
    } else {
      _retryable.remove(id);
    }
  }

  Future<DownloadGroup> snapshot(LibraryItem source) async {
    LibraryItem current;
    try {
      current = (await library.item(source.id)).withParent(source.parentId);
    } on AppFailure catch (error) {
      if (error.status != 404) rethrow;
      return DownloadGroup(source: source, tracks: const []);
    }
    // Record ancestry even for a single downloaded track. Otherwise music
    // downloaded from search would have no browsable folder path offline.
    final roots = await library.collections();
    final rootIds = roots.map((e) => e.id).toSet();
    final aliases = <String, String>{};
    for (final root in roots) {
      for (final child in await library.children(root)) {
        aliases[child.id] = root.id;
      }
    }
    current = current.withParent(aliases[current.id] ?? current.parentId);
    var tracks = await library.tracks(current);
    final folders = <String, LibraryItem>{};
    if (!source.isTrack && !source.isPlaylist) {
      final directIds = (await library.children(
        current,
      )).map((e) => e.id).toSet();
      for (final folder in await library.folderTree(current)) {
        folders[folder.id] = folder.withParent(
          directIds.contains(folder.id)
              ? current.id
              : aliases[folder.id] ?? folder.parentId,
        );
      }
      tracks = tracks
          .map((e) => directIds.contains(e.id) ? e.withParent(current.id) : e)
          .toList();
    }
    final pending = <String>{
      if (current.parentId != null) current.parentId!,
      for (final track in tracks)
        if (track.parentId != null) aliases[track.id] ?? track.parentId!,
    };
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final id = pending.first;
      pending.remove(id);
      if (!visited.add(id) || rootIds.contains(id)) continue;
      final folder = folders[id] ?? await library.item(id);
      final node = folder.withParent(aliases[id] ?? folder.parentId);
      folders[id] = node;
      if (node.parentId != null) pending.add(node.parentId!);
    }
    tracks = tracks
        .map((e) => e.withParent(aliases[e.id] ?? e.parentId))
        .toList();
    final orderedFolders = folders.values.toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return DownloadGroup(
      source: current,
      tracks: tracks,
      folders: orderedFolders,
    );
  }

  Future<void> add(LibraryItem source) async {
    final generation = _generation;
    final version = (_sourceVersions[source.id] ?? 0) + 1;
    _sourceVersions[source.id] = version;
    if (_batch.values.every((track) => contains(track.id))) _batch.clear();
    _pendingSources[source.id] = source;
    _preparing.add(source.id);
    _preparationErrors.remove(source.id);
    _retryableSources.remove(source.id);
    _scheduleSave();
    _changed(immediate: true);
    try {
      final group = await snapshot(source);
      await _mutations.run(() async {
        if (_disposed ||
            _generation != generation ||
            _sourceVersions[source.id] != version) {
          return;
        }
        _pendingSources.remove(source.id);
        _retryableSources.remove(source.id);
        _preparationErrors.remove(source.id);
        await _apply(group);
      });
    } catch (error) {
      if (!_disposed &&
          _generation == generation &&
          _sourceVersions[source.id] == version) {
        final permanent =
            error is AppFailure &&
            (error.status == 401 || error.status == 403 || error.status == 404);
        if (!permanent) _retryableSources.add(source.id);
        _preparationErrors[source.id] = permanent
            ? 'Не удалось получить состав. Проверьте доступ к серверу.'
            : 'Не удалось связаться с сервером. Повторим подготовку автоматически.';
        _scheduleSave();
        _scheduleRetry();
      }
      rethrow;
    } finally {
      if (_sourceVersions[source.id] == version) _preparing.remove(source.id);
      _changed();
    }
  }

  Future<void> apply(DownloadGroup group) {
    final version = (_sourceVersions[group.source.id] ?? 0) + 1;
    final generation = _generation;
    _sourceVersions[group.source.id] = version;
    return _mutations.run(() async {
      if (generation != _generation ||
          _sourceVersions[group.source.id] != version) {
        return;
      }
      await _apply(group);
    });
  }

  Future<void> _apply(DownloadGroup group) async {
    final generation = _generation;
    final version = _sourceVersions[group.source.id];
    final old = groups[group.source.id];
    groups[group.source.id] = group;
    _includeBatch(group.tracks);
    _changed(immediate: true);
    await _save();
    if (old != null) await _collectUnreferenced(old.tracks);
    for (final track in group.tracks) {
      if (generation != _generation ||
          version != _sourceVersions[group.source.id]) {
        break;
      }
      await _enqueue(track);
    }
    _changed();
  }

  Future<void> _enqueue(LibraryItem track) async {
    if (_files.containsKey(track.id)) {
      if (await File(_path(_files[track.id]!)).exists()) return;
      _files.remove(track.id);
      _batch[track.id] = track;
    }
    final taskId = _taskIds[track.id];
    if (taskId != null && await backend.task(taskId) != null) {
      if (!(_statuses[track.id]?.isFinalState ?? false)) return;
      await backend.cancel(taskId);
    }
    final converted = library.requiresConversion(track);
    final extension = converted ? '.mp3' : p.extension(track.fileName);
    final suffix = RegExp(r'^\.[a-zA-Z0-9]{1,8}$').hasMatch(extension)
        ? extension
        : '.audio';
    final task = DownloadTask(
      url: library.downloadUri(track).toString(),
      headers: library.headers,
      filename: '${track.id}$suffix',
      directory: _directory,
      baseDirectory: BaseDirectory.applicationSupport,
      group: namespace,
      updates: Updates.statusAndProgress,
      requiresWiFi: !allowCellular,
      retries: 3,
      allowPause: !converted,
      metaData: track.id,
      displayName: track.title,
    );
    _taskIds[track.id] = task.taskId;
    progress[track.id] = 0;
    errors.remove(track.id);
    _retryable.remove(track.id);
    _statuses[track.id] = TaskStatus.enqueued;
    _lastActivity.remove(track.id);
    _stalled.remove(track.id);
    var accepted = false;
    try {
      accepted = await backend.enqueue(task);
    } catch (_) {
      /* Sanitized below. */
    }
    if (!accepted) {
      _statuses[track.id] = TaskStatus.failed;
      _recordFailure(track.id, TaskStatus.failed, null);
      _scheduleRetry();
    }
    _scheduleSave();
    _changed();
  }

  Future<List<DownloadChange>> changes() async {
    final changes = <DownloadChange>[];
    // Build every snapshot first; a partial network failure never implies deletion.
    for (final group in List.of(groups.values)) {
      DownloadGroup updated;
      try {
        updated = await snapshot(group.source);
      } on Object {
        rethrow;
      }
      if (group.fingerprint != updated.fingerprint) {
        changes.add(DownloadChange(group, updated));
      }
    }
    return changes;
  }

  Future<void> removeGroup(String id) {
    _sourceVersions[id] = (_sourceVersions[id] ?? 0) + 1;
    _pendingSources.remove(id);
    _preparationErrors.remove(id);
    _preparing.remove(id);
    _retryableSources.remove(id);
    return _mutations.run(() => _removeGroup(id));
  }

  Future<void> _removeGroup(String id) async {
    final group = groups.remove(id);
    await _save();
    if (group != null) await _collectUnreferenced(group.tracks);
    _changed();
  }

  Future<void> removeTrack(String id) => removeTracks({id});

  Future<void> removeTracks(Set<String> ids) {
    final selected = Set<String>.of(ids);
    for (final group in groups.values) {
      if (group.tracks.any((track) => selected.contains(track.id))) {
        _sourceVersions[group.source.id] =
            (_sourceVersions[group.source.id] ?? 0) + 1;
      }
    }
    return _mutations.run(() => _removeTracks(selected));
  }

  Future<void> _removeTracks(Set<String> ids) async {
    // Include IDs without group metadata after an interrupted deletion.
    final affected = ids
        .map((id) => LibraryItem(id: id, name: '', kind: ItemKind.track))
        .toList();
    for (final group in List.of(groups.values)) {
      final remaining = group.tracks.where((t) => !ids.contains(t.id)).toList();
      if ((ids.contains(group.source.id) && group.source.isTrack) ||
          (remaining.isEmpty && group.tracks.isNotEmpty)) {
        groups.remove(group.source.id);
      } else {
        groups[group.source.id] = DownloadGroup(
          source: group.source,
          tracks: remaining,
          folders: group.folders,
        );
      }
    }
    await _save();
    await _collectUnreferenced(affected);
    _changed();
  }

  Future<void> _collectUnreferenced(List<LibraryItem> candidates) async {
    final referenced = groups.values
        .expand((g) => g.tracks)
        .map((t) => t.id)
        .toSet();
    for (final track in candidates) {
      if (referenced.contains(track.id)) continue;
      final taskId = _taskIds.remove(track.id);
      if (taskId != null) await backend.cancel(taskId);
      final name = _files.remove(track.id);
      if (name != null) {
        final file = File(_path(name));
        if (await file.exists()) await file.delete();
      }
      progress.remove(track.id);
      errors.remove(track.id);
      _batch.remove(track.id);
      _statuses.remove(track.id);
      _lastActivity.remove(track.id);
      _stalled.remove(track.id);
      _retryable.remove(track.id);
    }
    await _save();
  }

  Future<void> clear() {
    _generation++;
    _pendingSources.clear();
    _preparationErrors.clear();
    _preparing.clear();
    _retryableSources.clear();
    _retryTimer?.cancel();
    _stallTimer?.cancel();
    _lastActivity.clear();
    _stalled.clear();
    return _mutations.run(_clear);
  }

  Future<void> _clear() async {
    final all = groups.values.expand((g) => g.tracks).toList();
    groups.clear();
    await _save();
    await _collectUnreferenced(all);
    // Also remove orphaned files left by an interrupted deletion.
    final dir = Directory(p.join(store.directory.path, _directory));
    if (await dir.exists()) await dir.delete(recursive: true);
    _files.clear();
    await _save();
    _changed();
  }

  Future<void> setCellular(bool value) async {
    final generation = _generation;
    allowCellular = value;
    for (final id in List.of(progress.keys)) {
      if (generation != _generation || allowCellular != value) break;
      final taskId = _taskIds[id];
      final task = taskId == null ? null : await backend.task(taskId);
      if (task is DownloadTask) {
        await backend.cancel(task.taskId);
        if (generation == _generation &&
            allowCellular == value &&
            groups.values.any(
              (group) => group.tracks.any((track) => track.id == id),
            )) {
          await backend.enqueue(task.copyWith(requiresWiFi: !value));
        }
      }
    }
    _changed(immediate: true);
    if (_networkAllowed) unawaited(retryPending());
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    _notificationTimer?.cancel();
    _saveTimer?.cancel();
    _retryTimer?.cancel();
    _stallTimer?.cancel();
    super.dispose();
  }
}
