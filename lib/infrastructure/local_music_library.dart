import '../l10n/l10n.dart';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../domain/library_item.dart';
import 'local_store.dart';

class LocalMusicLibrary {
  LocalMusicLibrary(this.store);
  final LocalStore store;
  static const channel = MethodChannel('online.tavhome.simplefy/local_music');
  static const rootId = 'local:root';
  static LibraryItem get root => LibraryItem(
    id: rootId,
    name: L10n.current.onDevice,
    kind: ItemKind.collection,
  );
  final Map<String, LibraryItem> _items = {};
  Map<String, int> _trackCounts = {};
  int? trackCount(LibraryItem item) => contains(item.id)
      ? (item.isTrack ? 1 : _trackCounts[item.id] ?? 0)
      : null;
  Future<void> _recount() async {
    _trackCounts = await compute(_countLocalTracks, _items.values.toList());
  }

  bool get isEmpty => _items.isEmpty;
  bool contains(String id) => id == rootId || _items.containsKey(id);

  Future<void> initialize() async {
    final data = await store.read('local_music');
    for (final item in await compute(_decodeLocalItems, data['items'])) {
      _items[item.id] = item;
    }
    await _recount();
  }

  Future<int?> import({required bool folder}) async {
    final result = await channel.invokeMethod<List<dynamic>>(
      folder ? 'importFolder' : 'importFiles',
    );
    if (result == null) return null;
    final items = await compute(_decodeLocalItems, result);
    for (final item in items) {
      _items[item.id] = item;
    }
    await _recount();
    await _save();
    return items.where((e) => e.isTrack).length;
  }

  List<LibraryItem> children(LibraryItem parent) =>
      _items.values.where((e) => e.parentId == parent.id).toList()
        ..sort(compareItems);

  List<LibraryItem> tracks(LibraryItem parent, {bool recursive = true}) {
    if (parent.isTrack) return [parent];
    bool inside(LibraryItem item) {
      var cursor = item.parentId;
      final visited = <String>{};
      while (cursor != null && visited.add(cursor)) {
        if (cursor == parent.id) return true;
        if (!recursive) break;
        cursor = _items[cursor]?.parentId;
      }
      return false;
    }

    final result = _items.values.where((e) => e.isTrack && inside(e)).toList();
    String displayPath(LibraryItem item) {
      final parts = [item.filenameTitle];
      var cursor = item.parentId;
      final visited = <String>{};
      while (cursor != null && cursor != rootId && visited.add(cursor)) {
        final node = _items[cursor];
        if (node == null) break;
        parts.insert(0, node.name);
        cursor = node.parentId;
      }
      return parts.join('/').toLowerCase();
    }

    final paths = {for (final item in result) item.id: displayPath(item)};
    result.sort((a, b) {
      final order = paths[a.id]!.compareTo(paths[b.id]!);
      return order == 0 ? a.id.compareTo(b.id) : order;
    });
    return result;
  }

  String pathFor(LibraryItem item) => p.join(store.directory.path, item.path);

  Future<void> remove(LibraryItem item) async {
    final ids = {item.id, ...tracks(item).map((e) => e.id)};
    // Include empty folders too; only the imported copy belongs to this app.
    var changed = true;
    while (changed) {
      changed = false;
      for (final node in _items.values) {
        if (ids.contains(node.parentId) && ids.add(node.id)) changed = true;
      }
    }
    final selected = _items[item.id];
    for (final id in ids) {
      _items.remove(id);
    }
    await _recount();
    await _save();
    final relative = item.id == rootId ? 'local_music' : selected?.path;
    if (relative == null ||
        !p.isWithin(
              p.join(store.directory.path, 'local_music'),
              p.join(store.directory.path, relative),
            ) &&
            relative != 'local_music') {
      return;
    }
    final target = p.join(store.directory.path, relative);
    if (await FileSystemEntity.isDirectory(target)) {
      await Directory(target).delete(recursive: true);
    } else if (await File(target).exists()) {
      await File(target).delete();
    }
  }

  Future<void> _save() => store.write('local_music', {
    'items': _items.values.map((e) => e.toJson()).toList(),
  });
}

List<LibraryItem> _decodeLocalItems(Object? value) => decodeItems(value);

Map<String, int> _countLocalTracks(List<LibraryItem> items) {
  final nodes = {for (final item in items) item.id: item};
  final counts = <String, int>{};
  for (final track in items.where((e) => e.isTrack)) {
    var parent = track.parentId;
    final seen = <String>{};
    while (parent != null && seen.add(parent)) {
      counts[parent] = (counts[parent] ?? 0) + 1;
      parent = nodes[parent]?.parentId;
    }
  }
  return counts;
}
