import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../domain/download_group.dart';
import '../domain/library_item.dart';
import '../application/ports.dart';
import '../application/serial_executor.dart';
import 'jellyfin_library.dart';
import 'local_store.dart';

class DownloadManager extends ChangeNotifier {
  DownloadManager(this.store, this.library);
  // The plugin exposes one single-subscription stream for the whole process.
  // Keep its subscription stable across account logout/login.
  static final Stream<TaskUpdate> _events = FileDownloader().updates
      .asBroadcastStream();
  static Future<void>? _started;
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
    _subscription = _events.listen(_update);
    await (_started ??= FileDownloader().start());
    await _restoreRecords();
    final missing = <String>[];
    for (final id in List.of(_files.keys)) {
      if (!await File(_path(_files[id]!)).exists()) missing.add(id);
    }
    for (final id in missing) {
      _files.remove(id);
    }
    await _save();
  }

  Future<void> reconcile() => _mutations.run(() async {
    await FileDownloader().resumeFromBackground();
    await _restoreRecords();
    await _save();
    _changed();
  });

  Future<void> _restoreRecords() async {
    final referenced = groups.values
        .expand((g) => g.tracks)
        .map((t) => t.id)
        .toSet();
    final records = await FileDownloader().database.allRecords(
      group: namespace,
    );
    for (final record in records) {
      final id = record.task.metaData;
      if (!referenced.contains(id)) continue;
      _taskIds[id] = record.task.taskId;
      if (record.status == TaskStatus.complete &&
          await File(_path(record.task.filename)).exists()) {
        _files[id] = record.task.filename;
        progress.remove(id);
        errors.remove(id);
      } else if (!record.status.isFinalState && !_files.containsKey(id)) {
        progress[id] = record.progress.clamp(0, 1);
      }
    }
  }

  void _scheduleSave() {
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

  Future<void> _save() {
    _completedTracks = null;
    return store.write(_key, {
      'groups': groups.values.map((e) => e.toJson()).toList(),
      'files': Map.of(_files),
    });
  }

  void _changed() {
    if (_disposed) return;
    _notificationTimer ??= Timer(const Duration(milliseconds: 150), () {
      _notificationTimer = null;
      notifyListeners();
    });
  }

  void _update(TaskUpdate update) {
    if (update.task.group != namespace) return;
    final id = update.task.metaData;
    _taskIds[id] = update.task.taskId;
    if (update is TaskProgressUpdate) {
      progress[id] = update.progress.clamp(0, 1);
    } else if (update is TaskStatusUpdate) {
      if (update.status == TaskStatus.complete) {
        // A cancelled/removed group must not resurrect a completed file.
        if (groups.values.any((g) => g.tracks.any((t) => t.id == id))) {
          _files[id] = update.task.filename;
          _completedTracks = null;
          errors.remove(id);
          _scheduleSave();
        }
        progress.remove(id);
      } else if (update.status == TaskStatus.failed ||
          update.status == TaskStatus.notFound) {
        errors[id] = 'Не удалось скачать. Повторите загрузку.';
        progress.remove(id);
      } else if (update.status == TaskStatus.canceled) {
        progress.remove(id);
      } else {
        progress.putIfAbsent(id, () => 0);
      }
    }
    _changed();
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
    final group = await snapshot(source);
    await _mutations.run(() async {
      if (_generation != generation || _sourceVersions[source.id] != version) {
        return;
      }
      await _apply(group);
    });
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
    if (_files.containsKey(track.id) &&
        await File(_path(_files[track.id]!)).exists()) {
      return;
    }
    final taskId = _taskIds[track.id];
    if (taskId != null && await FileDownloader().taskForId(taskId) != null) {
      return;
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
    if (!await FileDownloader().enqueue(task)) {
      errors[track.id] = 'Загрузка не запущена';
      progress.remove(track.id);
    }
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
    return _mutations.run(() => _removeGroup(id));
  }

  Future<void> _removeGroup(String id) async {
    final group = groups.remove(id);
    if (group == null) return;
    await _save();
    await _collectUnreferenced(group.tracks);
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
      if (taskId != null) await FileDownloader().cancelTaskWithId(taskId);
      final name = _files.remove(track.id);
      if (name != null) {
        final file = File(_path(name));
        if (await file.exists()) await file.delete();
      }
      progress.remove(track.id);
      errors.remove(track.id);
    }
    await _save();
  }

  Future<void> clear() {
    _generation++;
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
      final task = taskId == null
          ? null
          : await FileDownloader().taskForId(taskId);
      if (task != null) {
        await FileDownloader().cancelTaskWithId(task.taskId);
        if (generation == _generation &&
            allowCellular == value &&
            groups.values.any(
              (group) => group.tracks.any((track) => track.id == id),
            )) {
          await FileDownloader().enqueue(task.copyWith(requiresWiFi: !value));
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    _notificationTimer?.cancel();
    _saveTimer?.cancel();
    super.dispose();
  }
}
