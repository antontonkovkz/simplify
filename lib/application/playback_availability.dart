import '../domain/library_item.dart';

/// One policy for rotation and offline presentation. Connectivity does not
/// remove occurrences, change playlist contents, or mark songs as consumed.
class PlaybackAvailability {
  const PlaybackAvailability({
    required this.streamingAllowed,
    required this.offline,
    required this.hasLocal,
  });
  final bool Function() streamingAllowed, offline;
  final bool Function(LibraryItem) hasLocal;
  bool canPlay(LibraryItem track) => streamingAllowed() || hasLocal(track);
  bool isUnavailable(LibraryItem item) => offline() && !hasLocal(item);
}
