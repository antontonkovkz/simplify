import 'dart:isolate';
import 'library_item.dart';

/// A top-level boundary only sends track data to the worker, never controllers,
/// HTTP clients, subscriptions, or native plugin objects.
Future<List<LibraryItem>> findTracks(
  List<LibraryItem> tracks,
  String query,
) async {
  final indices = await Isolate.run(
    () => [
      for (var index = 0; index < tracks.length; index++)
        if (tracks[index].matches(query)) index,
    ],
  );
  // Returning indices preserves the original occurrence identity, including
  // two appearances of the same track in a server playlist.
  return indices.map((index) => tracks[index]).toList();
}
