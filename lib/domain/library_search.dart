import 'dart:isolate';
import 'library_item.dart';

/// A top-level boundary only sends track data to the worker, never controllers,
/// HTTP clients, subscriptions, or native plugin objects.
Future<List<LibraryItem>> findTracks(
  List<LibraryItem> tracks,
  String query,
) async {
  final needle = query.trim().toLowerCase();
  final indices = await Isolate.run(
    () => [
      for (var index = 0; index < tracks.length; index++)
        if (tracks[index].matchesNeedle(needle)) index,
    ],
  );
  // Returning indices preserves the original occurrence identity, including
  // two appearances of the same track in a server playlist.
  return indices.map((index) => tracks[index]).toList();
}

/// Catalogue assembly also runs outside the UI isolate for large libraries.
Future<List<LibraryItem>> assembleSearchTracks(
  List<List<LibraryItem>> groups,
) async {
  if (groups.fold<int>(0, (count, tracks) => count + tracks.length) <= 32) {
    return _assemble(groups);
  }
  return Isolate.run(() => _assemble(groups));
}

List<LibraryItem> _assemble(List<List<LibraryItem>> groups) {
  final unique = <String, LibraryItem>{};
  for (final group in groups) {
    for (final track in group) {
      unique[track.id] = track;
    }
  }
  return List.unmodifiable(unique.values.toList()..sort(compareItems));
}
