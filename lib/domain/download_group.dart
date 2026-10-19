import 'library_item.dart';

class DownloadGroup {
  const DownloadGroup({
    required this.source,
    required this.tracks,
    this.folders = const [],
  });
  final LibraryItem source;
  final List<LibraryItem> tracks;
  final List<LibraryItem> folders;

  Map<String, dynamic> toJson() => {
    'source': source.toJson(),
    'tracks': tracks.map((e) => e.toJson()).toList(),
    'folders': folders.map((e) => e.toJson()).toList(),
  };
  factory DownloadGroup.fromJson(Map<String, dynamic> json) => DownloadGroup(
    source: LibraryItem.fromJson(
      Map<String, dynamic>.from(json['source'] as Map),
    ),
    tracks: decodeItems(json['tracks']),
    folders: decodeItems(json['folders']),
  );

  // Loudness metadata does not change membership/order or require downloads.
  static String _structure(LibraryItem item) =>
      (item.toJson()
            ..remove('normalizationGainDb')
            ..remove('albumNormalizationGainDb'))
          .toString();

  String get fingerprint => [
    _structure(source),
    ...folders.map((e) => _structure(e)),
    ...tracks.map((e) => _structure(e)),
  ].join('|');
}

class DownloadChange {
  const DownloadChange(this.before, this.after);
  final DownloadGroup before;
  final DownloadGroup after;
  int get added =>
      after.tracks.where((a) => !before.tracks.any((b) => b.id == a.id)).length;
  int get removed =>
      before.tracks.where((a) => !after.tracks.any((b) => b.id == a.id)).length;
}
