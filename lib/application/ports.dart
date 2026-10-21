import '../l10n/app_message.dart';
import '../domain/library_item.dart';

abstract interface class MusicLibrary {
  Future<List<LibraryItem>> collections();
  Future<List<LibraryItem>> playlists();
  Future<List<LibraryItem>> children(LibraryItem parent);
  Future<List<LibraryItem>> tracks(LibraryItem parent, {bool recursive = true});
}

enum NetworkKind { offline, unmetered, cellular, other }

enum SourceAvailability { available, missing, unauthorized, unreachable }

abstract interface class NetworkMonitor {
  Future<NetworkKind> current();
  Stream<NetworkKind> get changes;
}

class AppFailure implements Exception {
  const AppFailure(this.payload, {this.status});
  final Object payload;
  String get message =>
      payload is AppMessage ? (payload as AppMessage).text : payload.toString();
  final int? status;
  @override
  String toString() => message;
}

abstract interface class ServerPlaylists {
  Future<bool> canEditPlaylist(String id);
  Future<List<String>> playlistIds(String id);
  Future<void> validatePlaylistTracks(List<String> ids);
  Future<void> replacePlaylist(String id, List<String> ids);
}
