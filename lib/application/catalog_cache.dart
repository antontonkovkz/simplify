import 'dart:async';
import '../domain/library_item.dart';

/// Stale-while-revalidate snapshots, request coalescing and account generations.
class CatalogCache {
  CatalogCache(this.values, {required this.onChanged, required this.onStored});
  final Map<String, List<LibraryItem>> values;
  final void Function() onChanged;
  final void Function() onStored;
  final Map<String, Future<List<LibraryItem>>> _pending = {};
  final Map<String, Object> errors = {};
  final Map<String, int> _versions = {};
  int _generation = 0;
  bool _closed = false;
  bool updating(String key) => _pending.containsKey(key);

  Future<List<LibraryItem>> read(
    String key,
    Future<List<LibraryItem>> Function() fetch, {
    bool fresh = false,
  }) {
    final cached = values[key];
    final update = refresh(key, fetch);
    if (!fresh && cached != null) {
      unawaited(update.catchError((Object _) => cached));
      return Future.value(cached);
    }
    return update;
  }

  Future<List<LibraryItem>> refresh(
    String key,
    Future<List<LibraryItem>> Function() fetch,
  ) {
    if (_pending[key] case final existing?) return existing;
    final generation = _generation;
    final version = _versions[key] ?? 0;
    bool current() =>
        !_closed &&
        generation == _generation &&
        version == (_versions[key] ?? 0);
    final result = Completer<List<LibraryItem>>();
    _pending[key] = result.future;
    errors.remove(key);
    // Defer notifications/fetching until the requesting widget can finish build.
    scheduleMicrotask(() async {
      if (!current()) {
        result.completeError(StateError('Catalog scope changed'));
        return;
      }
      onChanged();
      try {
        final items = List<LibraryItem>.unmodifiable(await fetch());
        if (!current()) throw StateError('Catalog scope changed');
        values[key] = items;
        onStored();
        result.complete(items);
      } catch (error, stack) {
        if (current()) errors[key] = error;
        result.completeError(error, stack);
      } finally {
        if (current()) {
          _pending.remove(key);
          onChanged();
        }
      }
    });
    return result.future;
  }

  void invalidateKey(String key) {
    _versions[key] = (_versions[key] ?? 0) + 1;
    _pending.remove(key);
    errors.remove(key);
  }

  void invalidate() {
    _generation++;
    _versions.clear();
    _pending.clear();
    errors.clear();
  }

  void dispose() {
    _closed = true;
    invalidate();
  }
}
