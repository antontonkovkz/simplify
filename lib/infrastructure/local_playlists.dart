import 'dart:math';

import '../domain/library_item.dart';
import '../application/serial_executor.dart';
import 'local_store.dart';

/// Device-owned snapshots, isolated by the same account scope as the queue.
class LocalPlaylists {
  LocalPlaylists(this.store);
  final LocalStore store;
  final _mutations = SerialExecutor();
  String _key = 'playlists_state_local';
  Map<String, List<LibraryItem>> _tracks = {};
  Map<String, LibraryItem> _items = {};

  List<LibraryItem> get items => _items.values.toList()..sort(compareItems);
  int? trackCount(String id) => _tracks[id]?.length;
  LibraryItem? item(String? id) => _items[id];
  List<LibraryItem> tracks(String id) =>
      (_tracks[id] ?? []).map((e) => LibraryItem.fromJson(e.toJson())).toList();

  Future<void> load(String scope) => _mutations.run(() => _load(scope));

  Future<void> _load(String scope) async {
    final key = 'playlists_$scope';
    final data = await store.read(key);
    final items = <String, LibraryItem>{};
    final tracks = <String, List<LibraryItem>>{};
    for (final raw in data['playlists'] as List? ?? []) {
      final value = Map<String, dynamic>.from(raw as Map);
      final node = LibraryItem.fromJson(
        Map<String, dynamic>.from(value['item'] as Map),
      );
      items[node.id] = node;
      tracks[node.id] = decodeItems(value['tracks']);
    }
    _key = key;
    _items = items;
    _tracks = tracks;
  }

  Future<LibraryItem> save(
    List<LibraryItem> tracks, {
    String? id,
    String? name,
    bool allowEmpty = false,
  }) {
    final snapshot = List<LibraryItem>.of(tracks);
    return _mutations.run(
      () => _save(snapshot, id: id, name: name, allowEmpty: allowEmpty),
    );
  }

  Future<LibraryItem> _save(
    List<LibraryItem> tracks, {
    String? id,
    String? name,
    bool allowEmpty = false,
  }) async {
    if (tracks.isEmpty && !allowEmpty) {
      throw const FormatException('Очередь пуста');
    }
    final existing = _items[id];
    if (id != null && existing == null) {
      throw const FormatException(
        'Плейлист уже удалён. Выберите «Сохранить как».',
      );
    }
    final title = (name ?? existing?.name ?? '').trim();
    if (title.isEmpty) {
      throw const FormatException('Введите название плейлиста');
    }
    if (_items.values.any(
      (e) => e.id != id && e.name.toLowerCase() == title.toLowerCase(),
    )) {
      throw const FormatException('Плейлист с таким названием уже существует');
    }
    final random = Random.secure();
    final node = LibraryItem(
      id:
          id ??
          'local-playlist:${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}',
      name: title,
      kind: ItemKind.playlist,
    );
    final nextItems = {..._items, node.id: node};
    final nextTracks = {..._tracks, node.id: List<LibraryItem>.of(tracks)};
    await _write(nextItems, nextTracks);
    _items = nextItems;
    _tracks = nextTracks;
    return node;
  }

  Future<void> delete(String id) => _mutations.run(() => _delete(id));

  Future<void> _delete(String id) async {
    final items = {..._items}..remove(id);
    final tracks = {..._tracks}..remove(id);
    await _write(items, tracks);
    _items = items;
    _tracks = tracks;
  }

  Future<void> _write(
    Map<String, LibraryItem> items,
    Map<String, List<LibraryItem>> tracks,
  ) => store.write(_key, {
    'playlists': items.values
        .map(
          (e) => {
            'item': e.toJson(),
            'tracks': tracks[e.id]!.map((t) => t.toJson()).toList(),
          },
        )
        .toList(),
  });
}
